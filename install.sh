#!/usr/bin/env bash
# ====================================================================
# Full Frappe v15 + ERPNext + HRMS + MMCY custom apps installer
# - Robust MariaDB handling (WSL/systemctl/mysqld_safe)
# - Private repo support via GITHUB_TOKEN
# - Fixture workarounds for problematic fixtures
# - Clone retries + zip fallback for flaky networks
# Tested on Ubuntu/WSL (defensive, idempotent)
# ====================================================================

set -euo pipefail
IFS=$'\n\t'

### ===== CONFIG =====
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
BENCH_NAME="frappe-bench"
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="mmcy.hrms"
SITE_PORT="8003"
MYSQL_USER="frappe"
MYSQL_PASS="frappe"
ROOT_MYSQL_PASS="root"      # used only when explicitly applied; script prefers unix_socket
ADMIN_PASS="admin"
USE_LOCAL_APPS=false
CUSTOM_HR_REPO_BASE="github.com/MMCY-Tech/custom-hrms.git"
CUSTOM_ASSET_REPO_BASE="github.com/MMCY-Tech/custom-asset-management.git"
CUSTOM_IT_REPO_BASE="github.com/MMCY-Tech/custom-it-operations.git"
MAX_MARIADB_PORT=3310

# Colors
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${LIGHT_BLUE}Starting full Frappe v15 + ERPNext + HRMS + custom apps installer...${NC}"
echo

export PATH="$HOME/.local/bin:$PATH"

# ===== WSL detection (function reused later) =====
is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null && return 0 || return 1
}

WSL=false
if is_wsl; then
  WSL=true
  echo -e "${YELLOW}Detected WSL environment. Will use WSL-safe MariaDB logic.${NC}"
fi

# ===== GitHub token prompt (for private repos) =====
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo -n "Enter GitHub Personal Access Token (with repo read access) or press Enter to skip (public repos ok): "
    read -r token_input
    if [ -n "$token_input" ]; then
      GITHUB_TOKEN="$token_input"
      export GITHUB_TOKEN
    fi
  fi
  GITHUB_USER="token"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
  else
    CUSTOM_HR_REPO="https://${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${CUSTOM_IT_REPO_BASE}"
  fi
fi

# ===== System update & base packages =====
echo -e "${LIGHT_BLUE}Updating system packages and installing base dependencies...${NC}"
sudo apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y

sudo apt install -y git curl wget python3 python3-venv python3-dev python3-pip \
  redis-server xvfb libfontconfig wkhtmltopdf mariadb-server mariadb-client \
  build-essential jq unzip net-tools ss lsof

# Node & Yarn
echo -e "${LIGHT_BLUE}Installing Node.js 18 and yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >/dev/null 2>&1 || true
sudo apt install -y nodejs
if ! command -v yarn >/dev/null 2>&1; then
  sudo npm install -g yarn || true
fi

# ===== MariaDB environment preparation (robust) =====
echo -e "${LIGHT_BLUE}Preparing MariaDB environment...${NC}"

MYSQL_DATA_DIR=/var/lib/mysql
MYSQL_RUN_DIR=/run/mysqld
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"

# ensure dirs & ownership
sudo mkdir -p "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" /etc/mysql/conf.d
sudo chown -R mysql:mysql "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR"
sudo chmod 750 "$MYSQL_DATA_DIR"

# Helper: try connecting as root via sudo mysql, or via root password if set
can_connect_with_sudo() {
  sudo mysql -e "SELECT 1;" >/dev/null 2>&1
}
can_connect_with_rootpass() {
  if [ -n "${ROOT_MYSQL_PASS:-}" ]; then
    mysql -u root -p"$ROOT_MYSQL_PASS" -e "SELECT 1;" >/dev/null 2>&1
  else
    return 1
  fi
}
mysql_exec() {
  # Usage: mysql_exec <<SQL ... SQL
  if can_connect_with_sudo; then
    sudo mysql "$@"
  elif can_connect_with_rootpass; then
    mysql -u root -p"$ROOT_MYSQL_PASS" "$@"
  else
    return 1
  fi
}

# kill stale mysql processes function
kill_stale_mariadb_processes() {
  for p in mysqld_safe mariadbd mysqld; do
    pids="$(pgrep -x "$p" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      echo -e "${YELLOW}Killing stale process $p: $pids${NC}"
      sudo kill -9 $pids >/dev/null 2>&1 || true
    fi
  done
}

# attempt to start mariadb via systemctl or mysqld_safe with fallbacks
start_wait_check_timeout=60
print_logs_and_exit() {
  echo "==== /tmp/mariadb.log (tail) ===="
  sudo sed -n '1,200p' /tmp/mariadb.log 2>/dev/null || true
  ERRLOG="/var/lib/mysql/$(hostname).err"
  if [ -f "$ERRLOG" ]; then
    echo
    echo "==== $ERRLOG (tail) ===="
    sudo sed -n '1,200p' "$ERRLOG" 2>/dev/null || true
  fi
}

start_mariadb_systemctl() {
  echo -e "${LIGHT_BLUE}Starting MariaDB via systemctl...${NC}"
  sudo systemctl enable mariadb >/dev/null 2>&1 || true
  sudo systemctl restart mariadb >/tmp/mariadb.log 2>&1 || true

  i=0
  until can_connect_with_sudo || can_connect_with_rootpass; do
    sleep 1; i=$((i+1))
    if [ $i -ge $start_wait_check_timeout ]; then
      echo -e "${RED}MariaDB did not start within ${start_wait_check_timeout}s (systemctl).${NC}"
      sudo cat /tmp/mariadb.log 2>/dev/null || true
      return 1
    fi
  done
  return 0
}

start_mariadb_mysqld_safe() {
  echo -e "${LIGHT_BLUE}Starting MariaDB with mysqld_safe (WSL or fallback)...${NC}"
  kill_stale_mariadb_processes
  sleep 1
  sudo rm -f "$MYSQL_SOCKET" /var/lib/mysql/*.pid /var/lib/mysql/*.sock 2>/dev/null || true

  sudo -u mysql mysqld_safe --datadir="$MYSQL_DATA_DIR" --socket="$MYSQL_SOCKET" --port=3306 &>/tmp/mariadb.log &
  sleep 1
  tail -n 40 /tmp/mariadb.log 2>/dev/null || true

  i=0
  until can_connect_with_sudo || can_connect_with_rootpass; do
    sleep 1; i=$((i+1))
    if [ $i -ge $start_wait_check_timeout ]; then
      echo -e "${RED}MariaDB did not start within ${start_wait_check_timeout}s (mysqld_safe).${NC}"
      return 1
    fi
  done
  return 0
}

# initialize db dir if empty (first time)
if [ ! -d "$MYSQL_DATA_DIR/mysql" ] || [ -z "$(ls -A "$MYSQL_DATA_DIR" 2>/dev/null)" ]; then
  echo -e "${YELLOW}Initializing MariaDB system tables (first time)...${NC}"
  if command -v mariadb-install-db >/dev/null 2>&1; then
    sudo mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
  else
    sudo mysql_install_db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
  fi
fi

# Try to use existing server first then try startup methods
if can_connect_with_sudo || can_connect_with_rootpass; then
  echo -e "${GREEN}MariaDB is already running and reachable.${NC}"
else
  if ! is_wsl && command -v systemctl >/dev/null 2>&1; then
    if ! start_mariadb_systemctl; then
      echo -e "${YELLOW}systemctl start failed — trying mysqld_safe fallback...${NC}"
      if ! start_mariadb_mysqld_safe; then
        echo -e "${RED}Initial start attempts failed. Will attempt a safe re-init (backup existing datadir) and restart once.${NC}"
        TIMESTAMP=$(date +%s)
        BACKUP_DIR="/var/lib/mysql_backup_$TIMESTAMP"
        echo -e "${YELLOW}Backing up current datadir to $BACKUP_DIR${NC}"
        sudo systemctl stop mariadb >/dev/null 2>&1 || true
        sudo mv "$MYSQL_DATA_DIR" "$BACKUP_DIR" || true
        sudo mkdir -p "$MYSQL_DATA_DIR"
        sudo chown -R mysql:mysql "$MYSQL_DATA_DIR"
        echo -e "${YELLOW}Running fresh mariadb-install-db after backup...${NC}"
        if command -v mariadb-install-db >/dev/null 2>&1; then
          sudo mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
        else
          sudo mysql_install_db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
        fi
        if ! start_mariadb_systemctl; then
          if ! start_mariadb_mysqld_safe; then
            echo -e "${RED}MariaDB still won't start after re-init. See logs below:${NC}"
            print_logs_and_exit
            exit 1
          fi
        fi
      fi
    fi
  else
    # WSL or no systemctl
    if ! start_mariadb_mysqld_safe; then
      echo -e "${YELLOW}mysqld_safe initial start failed. Attempting backup + re-init...${NC}"
      TIMESTAMP=$(date +%s)
      BACKUP_DIR="/var/lib/mysql_backup_$TIMESTAMP"
      kill_stale_mariadb_processes || true
      sudo mv "$MYSQL_DATA_DIR" "$BACKUP_DIR" || true
      sudo mkdir -p "$MYSQL_DATA_DIR"
      sudo chown -R mysql:mysql "$MYSQL_DATA_DIR"
      if command -v mariadb-install-db >/dev/null 2>&1; then
        sudo mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
      else
        sudo mysql_install_db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
      fi
      if ! start_mariadb_mysqld_safe; then
        echo -e "${RED}MariaDB still won't start after re-init. See logs below:${NC}"
        print_logs_and_exit
        exit 1
      fi
    fi
  fi
fi

echo -e "${GREEN}MariaDB is up and reachable.${NC}"

# Create DB user (frappe) using best available mysql_exec
echo -e "${LIGHT_BLUE}Creating DB user '${MYSQL_USER}' if needed...${NC}"
if mysql_exec <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS \`${MYSQL_USER}\`;
FLUSH PRIVILEGES;
SQL
then
  echo -e "${GREEN}DB user '${MYSQL_USER}' ensured.${NC}"
else
  echo -e "${RED}Failed to create DB user. Please check MariaDB access and logs above.${NC}"
  print_logs_and_exit
  exit 1
fi

# ===== Install frappe-bench CLI (pipx style via pip install --user) =====
echo -e "${LIGHT_BLUE}Installing frappe-bench CLI...${NC}"
sudo apt install -y pipx || true
# prefer pipx if available, else pip user install
if command -v pipx >/dev/null 2>&1; then
  pipx install frappe-bench || pipx upgrade --include-deps frappe-bench || true
else
  python3 -m pip install --user --upgrade pip setuptools
  python3 -m pip install --user frappe-bench || true
fi
export PATH="$HOME/.local/bin:$PATH"

# ===== Bench initialization & apps directory =====
echo -e "${LIGHT_BLUE}Initializing bench and fetching apps...${NC}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# init bench if not exists
if [ ! -d "$BENCH_NAME" ]; then
  bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 || true
fi
cd "$BENCH_NAME" || exit 1

# helper: robust clone with retries and zip fallback
clone_with_retry() {
  local url=$1
  local branch=$2
  local dest=$3
  local max_attempts=5
  local attempt=1
  local wait_time=10

  while [ $attempt -le $max_attempts ]; do
    echo -e "${YELLOW}Attempt $attempt/$max_attempts cloning $url (branch:${branch})...${NC}"
    rm -rf "$dest" 2>/dev/null || true

    if GIT_TRACE=0 git clone --depth 1 --branch "$branch" --single-branch "$url" "$dest" 2>&1 | tee /tmp/git_clone.log; then
      echo -e "${GREEN}✓ Successfully cloned $dest${NC}"
      return 0
    fi

    # check for transient network issues
    if grep -q -E "Connection timed out|Connection reset|Recv failure|early EOF" /tmp/git_clone.log; then
      echo -e "${YELLOW}Network error detected when cloning — retry after ${wait_time}s...${NC}"
      sleep $wait_time
      wait_time=$((wait_time * 2))
      if [ $wait_time -gt 120 ]; then wait_time=120; fi
    else
      echo -e "${YELLOW}Clone failed (non-network). Will try again after short delay...${NC}"
      sleep 5
    fi
    attempt=$((attempt + 1))
  done

  # fallback: try downloading zip of branch
  echo -e "${YELLOW}Attempting zip fallback for $url branch $branch...${NC}"
  local zip_url="${url%.git}/archive/refs/heads/${branch}.zip"
  local zip_file="/tmp/${dest##*/}.zip"
  rm -f "$zip_file" 2>/dev/null || true
  if command -v wget >/dev/null 2>&1; then
    if wget --timeout=60 --tries=3 -O "$zip_file" "$zip_url" 2>/dev/null; then
      mkdir -p "$dest"
      unzip -q "$zip_file" -d "$dest"
      local subfolder
      subfolder=$(ls -d "$dest"/*/ 2>/dev/null | head -n1 || true)
      if [ -n "$subfolder" ]; then
        mv "$subfolder"* "$dest/" 2>/dev/null || true
        rmdir "$subfolder" 2>/dev/null || true
      fi
      rm -f "$zip_file"
      echo -e "${GREEN}✓ Successfully downloaded and extracted $dest via zip fallback${NC}"
      return 0
    fi
  fi

  echo -e "${RED}Failed to clone or download $url after $max_attempts attempts.${NC}"
  return 1
}

# fetch core apps if absent
[ ! -d "apps/erpnext" ] && clone_with_retry "https://github.com/frappe/erpnext.git" "$ERPNEXT_BRANCH" "apps/erpnext"
[ ! -d "apps/hrms" ] && clone_with_retry "https://github.com/frappe/hrms.git" "$HRMS_BRANCH" "apps/hrms"

# fetch custom apps if absent
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  [ ! -d "apps/mmcy_hrms" ] && clone_with_retry "$CUSTOM_HR_REPO" "$CUSTOM_BRANCH" "apps/mmcy_hrms"
  [ ! -d "apps/mmcy_asset_management" ] && clone_with_retry "$CUSTOM_ASSET_REPO" "$CUSTOM_BRANCH" "apps/mmcy_asset_management"
  [ ! -d "apps/mmcy_it_operations" ] && clone_with_retry "$CUSTOM_IT_REPO" "$CUSTOM_BRANCH" "apps/mmcy_it_operations"
fi

# ensure Python venv is present for bench's env executables
if [ ! -d "env" ]; then
  bench setup requirements
fi

# create site: drop if exists then create new
echo -e "${LIGHT_BLUE}Creating site ${SITE_NAME} (dropping existing site if present)...${NC}"
# read DB name from site name (bench new-site will derive actual db name)
# attempt drop with bench (ignore failures)
bench drop-site "$SITE_NAME" --no-backup --force --mariadb-root-username root --mariadb-root-password "$ROOT_MYSQL_PASS" 2>/dev/null || true

# create site using localhost/127.0.0.1 (bench will use mysql client/socket)
bench new-site "$SITE_NAME" \
  --mariadb-root-username root \
  --mariadb-root-password "$ROOT_MYSQL_PASS" \
  --admin-password "$ADMIN_PASS" || {
    echo -e "${RED}bench new-site failed. Will try using sudo mysql (unix_socket) fallback...${NC}"
    # Fallback: create site by creating DB manually then running new-site with --no-mariadb-socket
    DBNAME=$(echo "$SITE_NAME" | sed 's/\./_/g')
    # create DB and user
    if mysql_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${DBNAME}\`;
CREATE USER IF NOT EXISTS '${DBNAME}'@'localhost' IDENTIFIED BY '${DB_PASS:-$ADMIN_PASS}';
GRANT ALL PRIVILEGES ON \`${DBNAME}\`.* TO '${DBNAME}'@'localhost';
FLUSH PRIVILEGES;
SQL
    then
      bench new-site "$SITE_NAME" \
        --db-host 127.0.0.1 \
        --db-port 3306 \
        --mariadb-root-username root \
        --mariadb-root-password "$ROOT_MYSQL_PASS" \
        --admin-password "$ADMIN_PASS" || {
          echo -e "${RED}bench new-site failed even after DB pre-created. See bench output above.${NC}"
          exit 1
        }
    else
      echo -e "${RED}Failed to pre-create DB for site. Check MariaDB access.${NC}"
      exit 1
    fi
  }

echo -e "${GREEN}Site ${SITE_NAME} created.${NC}"

# region: fixture workarounds for mmcy_hrms & mmcy_asset_management
# backup and temporarily remove problematic fixtures before install (if present)
echo -e "${LIGHT_BLUE}Preparing fixture workarounds for custom apps...${NC}"
APP="mmcy_hrms"
FIXTURE_DIR="apps/$APP/$APP/fixtures"
TEMP_FIXTURE_DIR="/tmp/${APP}_fixtures_backup"
if [ -d "$FIXTURE_DIR" ]; then
  mkdir -p "$TEMP_FIXTURE_DIR"
  for f in leave_policy.json other_problematic_fixture.json; do
    if [ -f "$FIXTURE_DIR/$f" ]; then
      mv "$FIXTURE_DIR/$f" "$TEMP_FIXTURE_DIR/" || true
      echo "⏩ Temporarily moved $f for $APP"
    fi
  done
fi

APP2="mmcy_asset_management"
FIXTURE_DIR2="apps/$APP2/$APP2/fixtures"
TEMP_FIXTURE_DIR2="/tmp/${APP2}_fixtures_backup"
if [ -d "$FIXTURE_DIR2" ]; then
  mkdir -p "$TEMP_FIXTURE_DIR2"
  for f in account.json asset_category.json; do
    if [ -f "$FIXTURE_DIR2/$f" ]; then
      mv "$FIXTURE_DIR2/$f" "$TEMP_FIXTURE_DIR2/" || true
      echo "⏩ Temporarily moved $f for $APP2"
    fi
  done
fi
# endregion

# Install core apps first
echo -e "${LIGHT_BLUE}Installing ERPNext and HRMS into site ${SITE_NAME}...${NC}"
bench --site "$SITE_NAME" install-app erpnext || { echo -e "${RED}Failed to install erpnext${NC}"; exit 1; }
bench --site "$SITE_NAME" install-app hrms || { echo -e "${RED}Failed to install hrms${NC}"; exit 1; }

# Restore fixture files and install custom apps
echo -e "${LIGHT_BLUE}Installing custom apps...${NC}"
# restore mmcy_hrms fixtures
if [ -d "$TEMP_FIXTURE_DIR" ]; then
  mv "$TEMP_FIXTURE_DIR"/* "apps/mmcy_hrms/mmcy_hrms/fixtures/" 2>/dev/null || true
  rmdir "$TEMP_FIXTURE_DIR" 2>/dev/null || true
fi
bench --site "$SITE_NAME" install-app mmcy_hrms || { echo -e "${RED}Failed to install mmcy_hrms${NC}"; exit 1; }

# restore mmcy_asset_management fixtures
if [ -d "$TEMP_FIXTURE_DIR2" ]; then
  mv "$TEMP_FIXTURE_DIR2"/* "apps/mmcy_asset_management/mmcy_asset_management/fixtures/" 2>/dev/null || true
  rmdir "$TEMP_FIXTURE_DIR2" 2>/dev/null || true
fi
bench --site "$SITE_NAME" install-app mmcy_asset_management || { echo -e "${RED}Failed to install mmcy_asset_management${NC}"; exit 1; }

# Install IT operations
bench --site "$SITE_NAME" install-app mmcy_it_operations || { echo -e "${RED}Failed to install mmcy_it_operations${NC}"; exit 1; }

# Run migrations, build and setup Procfile/hosts
echo -e "${LIGHT_BLUE}Running migrate, build and final steps...${NC}"
bench --site "$SITE_NAME" migrate || true
bench build || true
sed -i '/^web:/d' Procfile || true
echo "web: bench serve --port ${SITE_PORT}" >> Procfile || true

# ensure hosts entry
if ! grep -q "^127.0.0.1[[:space:]]\+${SITE_NAME}\$" /etc/hosts; then
  echo "127.0.0.1 ${SITE_NAME}" | sudo tee -a /etc/hosts >/dev/null
fi

echo -e "${GREEN}Setup finished!${NC}"
echo -e " cd ${INSTALL_DIR}/${BENCH_NAME} && bench start"
echo -e " cd ${INSTALL_DIR}/${BENCH_NAME} && bench --site ${SITE_NAME} serve --port ${SITE_PORT}"
echo -e "${GREEN}Admin password: ${ADMIN_PASS}${NC}"

# Print installed apps (quick verification)
echo -e "${LIGHT_BLUE}Installed apps (brief):${NC}"
bench --site "$SITE_NAME" list-apps || true

exit 0
