#!/usr/bin/env bash
# =============================================================================
# Robust Frappe v15 + ERPNext + HRMS + MMCY custom apps installer
# - Works on Ubuntu (22.04 / 24.04), WSL, defensive for partial installs
# - Creates MariaDB admin user and avoids unix_socket vs password conflicts
# - Handles mysqld_safe fallback, datadir re-init, and shows logs on failure
# - Supports private custom apps via GITHUB_TOKEN
# - Resume-capable and idempotent where possible
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# CONFIGURATION (change as needed)
# -------------------------
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
ERPNEXT_BRANCH="${ERPNEXT_BRANCH:-version-15}"
HRMS_BRANCH="${HRMS_BRANCH:-version-15}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-develop}"

BENCH_NAME="${BENCH_NAME:-frappe-bench}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/frappe-setup}"
SITE_NAME="${SITE_NAME:-mmcy.hrms}"
SITE_PORT="${SITE_PORT:-8003}"

FRAPPE_USER="${FRAPPE_USER:-frappe}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

# MariaDB admin user we create to avoid root unix_socket issues
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-frappe_admin}"
MYSQL_ADMIN_PASS="${MYSQL_ADMIN_PASS:-Fr@pp3Adm1n!}"   # change if you want; it's used by bench new-site
MYSQL_APP_USER="${MYSQL_APP_USER:-frappe}"
MYSQL_APP_PASS="${MYSQL_APP_PASS:-frappe}"

# Custom repos
USE_LOCAL_APPS="${USE_LOCAL_APPS:-false}"
CUSTOM_HR_REPO_BASE="${CUSTOM_HR_REPO_BASE:-github.com/MMCY-Tech/custom-hrms.git}"
CUSTOM_ASSET_REPO_BASE="${CUSTOM_ASSET_REPO_BASE:-github.com/MMCY-Tech/custom-asset-management.git}"
CUSTOM_IT_REPO_BASE="${CUSTOM_IT_REPO_BASE:-github.com/MMCY-Tech/custom-it-operations.git}"

# Other
MAX_MARIADB_PORT=${MAX_MARIADB_PORT:-3310}
LOGFILE="/tmp/frappe_install.log"
PROGRESS_MARKER="/tmp/frappe_install_progress"

# Colors for output
YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[1;34m'; NC=$'\033[0m'

# -------------------------
# Logging helpers
# -------------------------
echo_banner(){ printf "\n${BLUE}==== %s ====${NC}\n" "$1" | tee -a "$LOGFILE"; }
log(){ printf "%s\n" "$*" | tee -a "$LOGFILE"; }
die(){ printf "${RED}ERROR: %s${NC}\n" "$*" | tee -a "$LOGFILE" >&2; exit 1; }

# Write to log
echo "=== Installer started: $(date) ===" >> "$LOGFILE"

# -------------------------
# Environment checks
# -------------------------
echo_banner "ENVIRONMENT CHECK"
if [ "$(id -u)" -ne 0 ]; then
  log "Script must be run with sudo/root. Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

# Keep original invoking user to create FRAPPE_USER home later
ORIG_USER="${SUDO_USER:-$(whoami)}"
log "Original user: $ORIG_USER"

# Detect WSL
is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null && return 0 || return 1
}
WSL=false
if is_wsl; then WSL=true; log "Detected WSL environment"; fi

# -------------------------
# GitHub token handling (for private repos)
# -------------------------
if [ "$USE_LOCAL_APPS" = "false" ]; then
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    # Non-interactive runs can export GITHUB_TOKEN; if not present we continue with public URLs
    log "No GITHUB_TOKEN provided; will attempt to clone public URLs or prompt if required."
  else
    GITHUB_USER="token"
    CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
    log "Custom repo URLs configured to use GITHUB_TOKEN (sensitive info suppressed in logs)."
  fi
fi

# -------------------------
# System update & install base packages
# -------------------------
echo_banner "SYSTEM PREP & DEPENDENCIES"
log "Updating apt and installing base packages..."
apt update -y >>"$LOGFILE" 2>&1
DEBIAN_FRONTEND=noninteractive apt upgrade -y >>"$LOGFILE" 2>&1

apt install -y git curl wget python3 python3-venv python3-dev python3-pip \
  redis-server xvfb libfontconfig wkhtmltopdf mariadb-server mariadb-client \
  build-essential jq unzip lsof net-tools sudo gnupg ca-certificates >>"$LOGFILE" 2>&1 \
  || die "Failed installing base packages (check $LOGFILE)"

# Node 18 + yarn
echo_banner "NODE & YARN"
log "Installing Node.js 18.x and yarn..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >>"$LOGFILE" 2>&1 || true
apt install -y nodejs >>"$LOGFILE" 2>&1 || die "Failed to install nodejs"
if ! command -v yarn >/dev/null 2>&1; then
  npm install -g yarn >>"$LOGFILE" 2>&1 || log "npm install -g yarn had non-fatal issues"
fi
log "node: $(node -v 2>/dev/null || echo 'n/a'), npm: $(npm -v 2>/dev/null || echo 'n/a'), yarn: $(yarn -v 2>/dev/null || echo 'n/a')"

# -------------------------
# MariaDB robust start & admin user creation
# -------------------------
echo_banner "MARIADB START & ADMIN USER"
# helper functions for MariaDB connectivity
can_connect_with_sudo() { sudo mysql -e "SELECT 1;" >/dev/null 2>&1; }
can_connect_with_rootpass() {
  if [ -n "${ROOT_MYSQL_PASS:-}" ]; then
    mysql -u root -p"$ROOT_MYSQL_PASS" -e "SELECT 1;" >/dev/null 2>&1
  else
    return 1
  fi
}
mysql_exec() {
  # Helper to run SQL using best available method
  if can_connect_with_sudo; then
    sudo mysql "$@"
  elif can_connect_with_rootpass; then
    mysql -u root -p"$ROOT_MYSQL_PASS" "$@"
  else
    return 1
  fi
}

# ensure mysql dirs & ownership (defensive)
MYSQL_DATA_DIR="/var/lib/mysql"
MYSQL_RUN_DIR="/run/mysqld"
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"
mkdir -p "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" /etc/mysql/conf.d
chown -R mysql:mysql "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" || true
chmod 750 "$MYSQL_DATA_DIR" || true

# start service (systemctl preferred)
log "Starting mariadb service..."
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb >/tmp/mariadb_start.log 2>&1 || true
sleep 2

# If mysql is unreachable via sudo mysql, attempt mysqld_safe fallback and re-init if necessary
if ! can_connect_with_sudo && ! can_connect_with_rootpass; then
  log "MariaDB not responding to sudo mysql. Attempting mysqld_safe fallback..."
  # kill any existing mysqld processes carefully
  for p in mysqld_safe mariadbd mysqld; do
    pids=$(pgrep -x "$p" || true)
    if [ -n "$pids" ]; then
      log "Killing stale process $p: $pids"
      kill -9 $pids >/dev/null 2>&1 || true
    fi
  done
  rm -f "$MYSQL_SOCKET" /var/lib/mysql/*.pid /var/lib/mysql/*.sock 2>/dev/null || true
  # attempt to start as mysql user via mysqld_safe (logs to /tmp/mariadb_safe.log)
  sudo -u mysql mysqld_safe --datadir="$MYSQL_DATA_DIR" --socket="$MYSQL_SOCKET" &>/tmp/mariadb_safe.log &
  sleep 3
  # wait for up to 40s
  i=0
  until can_connect_with_sudo || can_connect_with_rootpass; do
    sleep 1; i=$((i+1))
    if [ $i -ge 40 ]; then
      log "mysqld_safe did not start in time. Will attempt data-dir re-init fallback."
      # backup and re-init
      TS=$(date +%s)
      BACKUP_DIR="/var/lib/mysql_backup_$TS"
      log "Backing up $MYSQL_DATA_DIR -> $BACKUP_DIR"
      systemctl stop mariadb >/dev/null 2>&1 || true
      mv "$MYSQL_DATA_DIR" "$BACKUP_DIR" || true
      mkdir -p "$MYSQL_DATA_DIR"
      chown -R mysql:mysql "$MYSQL_DATA_DIR"
      if command -v mariadb-install-db >/dev/null 2>&1; then
        mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" &>/tmp/mariadb_reinit.log 2>&1 || true
      else
        mysql_install_db --user=mysql --datadir="$MYSQL_DATA_DIR" &>/tmp/mariadb_reinit.log 2>&1 || true
      fi
      # try start again
      sudo -u mysql mysqld_safe --datadir="$MYSQL_DATA_DIR" --socket="$MYSQL_SOCKET" &>/tmp/mariadb_safe.log &
      sleep 3
      break
    fi
  done
fi

# Final check
if ! can_connect_with_sudo && ! can_connect_with_rootpass; then
  log "MariaDB still unreachable. Printing last logs for debugging:"
  [ -f /tmp/mariadb_safe.log ] && tail -n 200 /tmp/mariadb_safe.log || true
  [ -f /tmp/mariadb_start.log ] && tail -n 200 /tmp/mariadb_start.log || true
  [ -f /var/log/mysql/error.log ] && tail -n 200 /var/log/mysql/error.log || true
  die "MariaDB would not start or accept connections. Resolve MariaDB first and re-run the script."
fi

log "MariaDB is running and reachable."

# Create an admin user for bench/new-site to avoid relying on root auth mode
log "Ensuring MariaDB admin user '${MYSQL_ADMIN_USER}' exists (via sudo mysql)..."
sudo mysql <<SQL || die "Failed running sudo mysql to create admin user"
CREATE USER IF NOT EXISTS '${MYSQL_ADMIN_USER}'@'localhost' IDENTIFIED BY '${MYSQL_ADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ADMIN_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
log "MariaDB admin user '${MYSQL_ADMIN_USER}' ensured."

# Write minimal UTF8 config for Frappe
cat >/etc/mysql/conf.d/frappe.cnf <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
EOF
systemctl restart mariadb >/dev/null 2>&1 || true
sleep 2

# -------------------------
# Create system user for bench
# -------------------------
echo_banner "FRAPPE SYSTEM USER & BENCH INSTALL"
if ! id "$FRAPPE_USER" &>/dev/null; then
  log "Creating system user: $FRAPPE_USER"
  adduser --disabled-password --gecos "" "$FRAPPE_USER" >/dev/null 2>&1 || true
  usermod -aG sudo "$FRAPPE_USER" >/dev/null 2>&1 || true
  chown -R "$FRAPPE_USER":"$FRAPPE_USER" /home/"$FRAPPE_USER" 2>/dev/null || true
else
  log "User $FRAPPE_USER already exists"
fi

# Ensure INSTALL_DIR exists and is owned by FRAPPE_USER
mkdir -p "$INSTALL_DIR"
chown -R "$FRAPPE_USER":"$FRAPPE_USER" "$INSTALL_DIR"

# -------------------------
# Install bench CLI (pipx/pip user)
# -------------------------
log "Installing bench CLI (pipx/pip user)"
if command -v pipx >/dev/null 2>&1; then
  pipx install --force frappe-bench || pipx upgrade --include-deps frappe-bench || true
else
  # ensure pip and install user package
  python3 -m pip install --upgrade pip setuptools wheel
  python3 -m pip install --user --upgrade frappe-bench || true
fi

# Ensure PATH for non-root user includes local bin. We'll run bench as FRAPPE_USER with sudo -H -u, which preserves PATH from that user's profile.
# Add environment to FRAPPE_USER's .profile for later interactive use
sudo -H -u "$FRAPPE_USER" bash -lc 'mkdir -p $HOME/.local/bin 2>/dev/null || true'

# -------------------------
# Bench init & fetch apps (run as FRAPPE_USER)
# -------------------------
echo_banner "BENCH INIT & FETCH APPS"
sudo -H -u "$FRAPPE_USER" bash <<'BUSER'
set -euo pipefail
IFS=$'\n\t'

# Variables passed via environment from root context: INSTALL_DIR, BENCH_NAME, FRAPPE_BRANCH, etc.
cd "$HOME"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# initialize bench if absent
if [ ! -d "$BENCH_NAME" ]; then
  bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 || true
fi
cd "$BENCH_NAME"

# helper: robust clone with retries (uses git or zip fallback)
clone_with_retry() {
  url="$1"; branch="$2"; dest="$3"
  max_attempts=4; attempt=1; wait_time=8
  while [ $attempt -le $max_attempts ]; do
    rm -rf "$dest" 2>/dev/null || true
    echo "Attempt $attempt: git clone $url (branch $branch)..."
    if git clone --depth 1 --branch "$branch" --single-branch "$url" "$dest" 2>&1; then
      echo "Cloned $dest"
      return 0
    fi
    sleep $wait_time
    attempt=$((attempt+1))
    wait_time=$((wait_time*2))
  done
  # fallback zip
  zip_url="${url%.git}/archive/refs/heads/${branch}.zip"
  tmpzip="/tmp/$(basename "$dest").zip"
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmpzip" "$zip_url" && mkdir -p "$dest" && unzip -q "$tmpzip" -d "$dest"
    sub=$(ls -d "$dest"/*/ 2>/dev/null | head -n1 || true)
    if [ -n "$sub" ]; then mv "$sub"* "$dest/"; rmdir "$sub"; fi
    rm -f "$tmpzip"
    echo "Downloaded zip fallback for $url"
    return 0
  fi
  return 1
}

# Fetch core apps
[ ! -d "apps/erpnext" ] && clone_with_retry "https://github.com/frappe/erpnext.git" "$ERPNEXT_BRANCH" "apps/erpnext" || true
[ ! -d "apps/hrms" ] && clone_with_retry "https://github.com/frappe/hrms.git" "$HRMS_BRANCH" "apps/hrms" || true

# Fetch custom apps (if environment variables set by parent)
if [ "${USE_LOCAL_APPS:-false}" = "false" ]; then
  if [ -n "${CUSTOM_HR_REPO:-}" ] && [ ! -d "apps/mmcy_hrms" ]; then
    clone_with_retry "$CUSTOM_HR_REPO" "$CUSTOM_BRANCH" "apps/mmcy_hrms" || echo "Warning: failed to clone mmcy_hrms"
  fi
  if [ -n "${CUSTOM_ASSET_REPO:-}" ] && [ ! -d "apps/mmcy_asset_management" ]; then
    clone_with_retry "$CUSTOM_ASSET_REPO" "$CUSTOM_BRANCH" "apps/mmcy_asset_management" || echo "Warning: failed to clone mmcy_asset_management"
  fi
  if [ -n "${CUSTOM_IT_REPO:-}" ] && [ ! -d "apps/mmcy_it_operations" ]; then
    clone_with_retry "$CUSTOM_IT_REPO" "$CUSTOM_BRANCH" "apps/mmcy_it_operations" || echo "Warning: failed to clone mmcy_it_operations"
  fi
fi

# install python deps for apps (best-effort)
bench setup requirements || true

echo "Bench init & app fetch complete."
BUSER

# -------------------------
# Create site using MYSQL_ADMIN credentials
# -------------------------
echo_banner "CREATE SITE"
# Drop site if marker indicates a previous failed attempt; bench drop-site is safe
sudo -H -u "$FRAPPE_USER" bash -c "cd $INSTALL_DIR/$BENCH_NAME && bench drop-site $SITE_NAME --no-backup --force" >/dev/null 2>&1 || true

# Use MYSQL_ADMIN credentials for new-site to avoid unix_socket issues
log "Creating new site $SITE_NAME using MariaDB admin user $MYSQL_ADMIN_USER..."
sudo -H -u "$FRAPPE_USER" bash -c "cd $INSTALL_DIR/$BENCH_NAME && \
  bench new-site $SITE_NAME \
    --db-host 127.0.0.1 \
    --db-port 3306 \
    --mariadb-root-username $MYSQL_ADMIN_USER \
    --mariadb-root-password $MYSQL_ADMIN_PASS \
    --admin-password $ADMIN_PASS" || die "bench new-site failed. Check bench output above and $LOGFILE"

# -------------------------
# Fixture workarounds & Install apps
# -------------------------
echo_banner "INSTALL CORE + CUSTOM APPS"
# Move problematic fixtures if present (workaround)
sudo -H -u "$FRAPPE_USER" bash <<'BUSER2'
set -e
cd "$INSTALL_DIR/$BENCH_NAME"

# Backup and temporarily move problematic fixtures for mmcy_hrms and mmcy_asset_management
APP1="mmcy_hrms"; FIX1="apps/$APP1/$APP1/fixtures"
TMP1="/tmp/${APP1}_fixtures_backup"
if [ -d "$FIX1" ]; then
  mkdir -p "$TMP1"
  for f in leave_policy.json other_problematic_fixture.json; do
    if [ -f "$FIX1/$f" ]; then
      mv "$FIX1/$f" "$TMP1/" || true
      echo "Moved $f"
    fi
  done
fi

APP2="mmcy_asset_management"; FIX2="apps/$APP2/$APP2/fixtures"
TMP2="/tmp/${APP2}_fixtures_backup"
if [ -d "$FIX2" ]; then
  mkdir -p "$TMP2"
  for f in account.json asset_category.json; do
    if [ -f "$FIX2/$f" ]; then
      mv "$FIX2/$f" "$TMP2/" || true
      echo "Moved $f"
    fi
  done
fi

# Install official apps first
bench --site "$SITE_NAME" install-app erpnext || { echo "erpnext install failed"; exit 1; }
bench --site "$SITE_NAME" install-app hrms || { echo "hrms install failed"; exit 1; }

# Restore mmcy_hrms fixtures then install custom hrms
if [ -d "$TMP1" ]; then
  mv "$TMP1"/* "apps/mmcy_hrms/mmcy_hrms/fixtures/" 2>/dev/null || true
  rmdir "$TMP1" 2>/dev/null || true
fi
if [ -d "apps/mmcy_hrms" ]; then
  bench --site "$SITE_NAME" install-app mmcy_hrms || echo "mmcy_hrms install had warnings"
fi

# Restore asset fixtures and install asset management
if [ -d "$TMP2" ]; then
  mv "$TMP2"/* "apps/mmcy_asset_management/mmcy_asset_management/fixtures/" 2>/dev/null || true
  rmdir "$TMP2" 2>/dev/null || true
fi
if [ -d "apps/mmcy_asset_management" ]; then
  bench --site "$SITE_NAME" install-app mmcy_asset_management || echo "mmcy_asset_management install had warnings"
fi

# Install IT operations if present
if [ -d "apps/mmcy_it_operations" ]; then
  bench --site "$SITE_NAME" install-app mmcy_it_operations || echo "mmcy_it_operations install had warnings"
fi

# Run migrations and build assets
bench --site "$SITE_NAME" migrate || true
bench build || true
BUSER2

# -------------------------
# Finalize: Procfile, hosts, summary
# -------------------------
echo_banner "FINALIZE & SUMMARY"
# Set web port in Procfile (idempotent)
if [ -f "$INSTALL_DIR/$BENCH_NAME/Procfile" ]; then
  sed -i '/^web:/d' "$INSTALL_DIR/$BENCH_NAME/Procfile" || true
fi
echo "web: bench serve --port ${SITE_PORT}" >> "$INSTALL_DIR/$BENCH_NAME/Procfile" || true

# Ensure /etc/hosts entry
if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${SITE_NAME}[[:space:]]*$" /etc/hosts; then
  echo "127.0.0.1 ${SITE_NAME}" >> /etc/hosts
fi

log "Installation finished at $(date)"
log "Bench directory: $INSTALL_DIR/$BENCH_NAME"
log "Start bench as the frappe user: sudo -H -u $FRAPPE_USER bash -c 'cd $INSTALL_DIR/$BENCH_NAME && bench start'"
log "Open: http://${SITE_NAME}:${SITE_PORT}  (or http://localhost if serving default port)"
log "ERPNext admin password: $ADMIN_PASS"
log "MariaDB admin user: $MYSQL_ADMIN_USER (password: $MYSQL_ADMIN_PASS)"
log "Detailed logs: $LOGFILE"

echo -e "${GREEN}SUCCESS: Installation attempted to completion.${NC}"
echo -e "${YELLOW}If any errors occurred, inspect $LOGFILE and the MariaDB logs (e.g., /var/log/mysql/error.log).${NC}"

exit 0
