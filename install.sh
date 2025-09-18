#!/usr/bin/env bash
# One-command Frappe v15 + ERPNext + HRMS + custom apps installer (local Ubuntu/WSL)
set -euo pipefail

### ===== CONFIG =====
# This section defines all customizable variables for the installation.
# - Branches: Specifies Git branches for Frappe, ERPNext, HRMS, and custom apps.
# - Paths: Sets the bench name, install directory, site name, and port.
# - Database: Credentials for MariaDB (frappe user for bench, root for admin).
# - Apps: Flag for local vs. remote custom apps; repo bases for MMCY custom apps.
# To customize: Edit these before running (e.g., change SITE_NAME for multi-site setups).
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
BENCH_NAME="frappe-bench"
INSTALL_DIR="$HOME/frappe-setup"
SITE_NAME="mmcy.hrms"
SITE_PORT="8003"
MYSQL_USER="frappe"
MYSQL_PASS="frappe"
ROOT_MYSQL_PASS="root"
ADMIN_PASS="admin"
USE_LOCAL_APPS=false
CUSTOM_HR_REPO_BASE="github.com/MMCY-Tech/custom-hrms.git"
CUSTOM_ASSET_REPO_BASE="github.com/MMCY-Tech/custom-asset-management.git"
CUSTOM_IT_REPO_BASE="github.com/MMCY-Tech/custom-it-operations.git"

### ===== COLORS =====
# ANSI color codes for user-friendly terminal output.
# Used throughout for progress (blue), success (green), warnings (yellow), errors (red).
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

# Startup message and PATH export.
# Prints the install location and adds ~/.local/bin to PATH for tools like bench (installed later).
echo -e "${LIGHT_BLUE}Starting one-command Frappe v15 setup...${NC}"
echo "Bench will be installed to: $INSTALL_DIR/$BENCH_NAME"
echo

export PATH="$HOME/.local/bin:$PATH"

# WSL Detection Function and Check
# - Defines is_wsl() to detect WSL via /proc/version (checks for "microsoft" or "wsl").
# - Sets WSL=true if detected; prints a warning for users.
# Purpose: Allows WSL-specific tweaks (e.g., MariaDB port handling later) while keeping native Ubuntu compatible.
is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null || false
}

WSL=false
if is_wsl; then
  WSL=true
  echo -e "${YELLOW}Detected WSL environment. Will use WSL-safe MariaDB logic.${NC}"
fi

# Secure GitHub Token Handling for Custom Apps
# - If USE_LOCAL_APPS=false (default), checks for GITHUB_TOKEN env var.
# - If missing, prompts with read -s (hidden input) for a PAT with repo read access.
# - Constructs authenticated HTTPS URLs using a dummy username ("token") to avoid exposing real user.
# - No echoes of URLs or tokens; suppresses git output later to hide in logs.
# Purpose: Securely fetches private custom apps without exposing credentials in console/history.
# Tip: Set export GITHUB_TOKEN=ghp_... before running to skip prompt.
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -s -p "Enter your GitHub Personal Access Token (with repo read access): " GITHUB_TOKEN
    echo
  fi
  GITHUB_USER="token"  # Dummy user for HTTPS auth; token acts as both
  CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
  CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
  CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
fi

# System Update and Core Package Installation
# - Runs apt update/upgrade to ensure latest packages.
# - Installs Ubuntu/WSL essentials: Git/curl/wget for downloads; Python3 + venv/pip/dev for Frappe runtime;
#   Redis for background jobs; xvfb/libfontconfig/wkhtmltopdf for PDF generation; MariaDB for database;
#   build-essential for compiling; jq for JSON parsing (used later for config).
# Purpose: Prepares the environment; fails fast if sudo access is denied.
echo -e "${LIGHT_BLUE}Updating system and installing core packages...${NC}"
sudo apt update
sudo apt upgrade -y
sudo apt install -y git curl wget python3 python3-venv python3-dev python3-pip \
    redis-server xvfb libfontconfig wkhtmltopdf mariadb-server mariadb-client build-essential jq

# Node.js 18 and Yarn Installation
# - Adds NodeSource repo for Node.js 18 (Frappe v15 requirement).
# - Installs Node.js + npm via apt; verifies versions.
# - Installs Yarn globally via npm for asset building (JS/CSS).
# Purpose: Front-end dependencies; || true prevents failure on version print.
echo -e "${LIGHT_BLUE}Installing Node.js 18 and yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
node -v && npm -v || true
sudo npm install -g yarn
yarn -v || true

# MariaDB Environment Preparation
# - Creates essential directories (/run/mysqld for runtime, /var/lib/mysql for data, /etc/mysql/conf.d for configs).
# - Sets ownership to mysql user/group for security.
# - Scans ports 3306-3310 for conflicts using ss -ltnp (socket stats).
#   - If a MySQL/MariaDB process (via ps comm=) occupies the port, stops service (systemctl) or kills PID.
#   - Increments port if non-MariaDB process; breaks on free port.
# Purpose: Handles WSL/Ubuntu port clashes (e.g., existing MySQL); selects a safe DB_PORT.
# Gotcha: Requires sudo; may need manual stop of other DBs (e.g., sudo systemctl stop mysql).

### ===== MariaDB Setup =====

### ===== MariaDB Setup =====
echo -e "${LIGHT_BLUE}Preparing MariaDB environment...${NC}"

# Ensure directories exist
sudo mkdir -p /run/mysqld /var/lib/mysql /etc/mysql/conf.d
sudo chown -R mysql:mysql /run/mysqld /var/lib/mysql

# Kill any running MariaDB processes safely
sudo pkill -9 mariadbd || true
sudo pkill -9 mysqld || true
sudo pkill -9 mysqld_safe || true
sleep 2

# Remove stale sockets and locks
MYSQL_SOCKET="/run/mysqld/mysqld.sock"
sudo rm -f "$MYSQL_SOCKET"
sudo rm -f /var/lib/mysql/aria_log_control
sudo rm -f /var/lib/mysql/ibdata1.lock 2>/dev/null || true

# Pick an available port (3306–3310)
DB_PORT=3306
while ss -ltnp 2>/dev/null | grep -q ":$DB_PORT\b"; do
    DB_PORT=$((DB_PORT + 1))
done
echo -e "${GREEN}Using MariaDB port $DB_PORT.${NC}"

# Basic UTF8 config
sudo tee /etc/mysql/conf.d/frappe.cnf > /dev/null <<EOF
[mysqld]
port = $DB_PORT
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

# Initialize MariaDB only if not already initialized
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo -e "${LIGHT_BLUE}Initializing MariaDB system tables...${NC}"
    sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql
fi

# Start MariaDB safely
echo -e "${LIGHT_BLUE}Starting MariaDB...${NC}"
sudo -u mysql mysqld_safe --datadir=/var/lib/mysql --socket="$MYSQL_SOCKET" --port=$DB_PORT > /tmp/mariadb.log 2>&1 &

# Wait until MariaDB is ready
i=0
MAX_WAIT=120
until mysql -u root -e "SELECT 1;" >/dev/null 2>&1; do
    sleep 1
    i=$((i+1))
    if [ $i -ge $MAX_WAIT ]; then
        echo -e "${RED}MariaDB did not start within ${MAX_WAIT}s. Check /tmp/mariadb.log${NC}"
        exit 1
    fi
done
echo -e "${GREEN}MariaDB is up.${NC}"

# MariaDB Bench User Creation
echo -e "${LIGHT_BLUE}Creating DB user '${MYSQL_USER}'...${NC}"
mysql -u root <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS \`${MYSQL_USER}\`;
FLUSH PRIVILEGES;
SQL
echo -e "${GREEN}DB user '${MYSQL_USER}' ensured.${NC}"




# Frappe Bench CLI Installation
# - Installs pipx via apt for isolated Python tools.
# - Removes old bench binary; installs latest frappe-bench via pipx.
# - Ensures PATH and exports it.
# Purpose: bench is the Frappe CLI for init/get-app/install; pipx isolates it from system Python.
echo -e "${LIGHT_BLUE}Installing frappe-bench CLI...${NC}"
sudo apt install pipx -y
rm -f ~/.local/bin/bench
pipx install frappe-bench --force
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

# Bench Initialization
# - Creates INSTALL_DIR if missing.
# - Inits bench with Frappe branch (version-15) if not exists; verbose for logging.
# - CDs into bench dir.
# Purpose: Sets up virtualenv, sites/apps structure; skips if already initialized (idempotent).
echo -e "${LIGHT_BLUE}Initializing bench...${NC}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
if [ ! -d "$BENCH_NAME" ]; then
  bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --verbose
fi
cd "$BENCH_NAME"

# Fetching Core Apps (ERPNext, HRMS)
# - Checks if apps/erpnext or apps/hrms exist; clones from GitHub if not (specified branch).
# Purpose: Downloads official ERPNext/HRMS for business/HR features; idempotent.
echo -e "${LIGHT_BLUE}Fetching ERPNext and HRMS apps...${NC}"
[ ! -d "apps/erpnext" ] && bench get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext
[ ! -d "apps/hrms" ] && bench get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms

# Fetching Custom Apps
# - If USE_LOCAL_APPS=false, clones MMCY custom apps (hrms, asset_management, it_operations) from authenticated repos (develop branch).
# - Sets GIT_TRACE=0 and redirects stderr to suppress clone URLs/tokens in output.
# - Unsets after to restore defaults.
# Purpose: Adds organization-specific apps; skips if local (set USE_LOCAL_APPS=true for testing).
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  # Suppress git trace and bench verbose to hide token in output
  export GIT_TRACE=0
  [ ! -d "apps/mmcy_hrms" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_hrms "$CUSTOM_HR_REPO" 2>/dev/null
  [ ! -d "apps/mmcy_asset_management" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_asset_management "$CUSTOM_ASSET_REPO" 2>/dev/null
  [ ! -d "apps/mmcy_it_operations" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_it_operations "$CUSTOM_IT_REPO" 2>/dev/null
  unset GIT_TRACE
fi

# Site Creation
# - Drops existing site (force, no backup) to ensure clean start.
# - Creates new site with DB host/port, frappe user creds, and admin password.
# - || true prevents exit on non-fatal errors (e.g., site not existing).
# Purpose: Initializes the ERPNext site (mmcy.hrms); uses localhost for DB connection.
echo -e "${LIGHT_BLUE}Creating site ${SITE_NAME}...${NC}"
bench drop-site "$SITE_NAME" --no-backup --force --db-root-username "$MYSQL_USER" --db-root-password "$MYSQL_PASS" || true
bench new-site "$SITE_NAME" \
  --db-host localhost \
  --db-port "$DB_PORT" \
  --mariadb-root-username "$MYSQL_USER" \
  --mariadb-root-password "$MYSQL_PASS" \
  --admin-password "$ADMIN_PASS" || true

# Site-Specific DB User Fix
# - Parses site_config.json for DB name/password using jq.
# - Drops/recreates site-specific user (e.g., _db_name@local) with targeted grants on its DB only.
# Purpose: Enhances security (per-site user vs. shared frappe); fixes localhost/127.0.0.1 mismatches.
DB_NAME=$(jq -r '.db_name' "sites/${SITE_NAME}/site_config.json")
DB_PWD=$(jq -r '.db_password' "sites/${SITE_NAME}/site_config.json")
mysql -u root -p"$ROOT_MYSQL_PASS" <<SQL
DROP USER IF EXISTS '${DB_NAME}'@'localhost';
DROP USER IF EXISTS '${DB_NAME}'@'127.0.0.1';
CREATE USER '${DB_NAME}'@'localhost' IDENTIFIED BY '${DB_PWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'localhost';
CREATE USER '${DB_NAME}'@'127.0.0.1' IDENTIFIED BY '${DB_PWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
echo -e "${GREEN}Site DB user fixed for localhost.${NC}"

# Core App Installation (ERPNext, HRMS)
# - Installs erpnext and hrms into the site, setting up schemas/default data.
# Purpose: Enables base functionality; done before custom apps to resolve dependencies.
echo -e "${LIGHT_BLUE}Installing apps into ${SITE_NAME} with fixture workaround...${NC}"
# Install core apps first
bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms

# Workaround for mmcy_hrms Fixtures
# - Backs up specific problematic fixtures (leave_policy.json, other_problematic_fixture.json) to /tmp.
# - Installs the app without them to avoid import errors (e.g., duplicates/invalids).
# - Restores after; rmdir cleans up.
# Purpose: Prevents install failures from bad fixtures; migrate later syncs them safely.
# -----------------------------
# Workaround for mmcy_hrms problematic fixtures
# -----------------------------
APP="mmcy_hrms"
FIXTURE_DIR="apps/$APP/$APP/fixtures"
TEMP_FIXTURE_DIR="/tmp/${APP}_fixtures_backup"
echo "Backing up fixture files for $APP..."
mkdir -p "$TEMP_FIXTURE_DIR"
mv "$FIXTURE_DIR/leave_policy.json" "$TEMP_FIXTURE_DIR/" 2>/dev/null || true
mv "$FIXTURE_DIR/other_problematic_fixture.json" "$TEMP_FIXTURE_DIR/" 2>/dev/null || true
bench --site "$SITE_NAME" install-app "$APP"
echo "Restoring fixture files for $APP..."
mv "$TEMP_FIXTURE_DIR"/* "$FIXTURE_DIR/" 2>/dev/null || true
rmdir "$TEMP_FIXTURE_DIR" 2>/dev/null || true

# Workaround for mmcy_asset_management Fixtures
# - Moves account.json and asset_category.json (causing fixed_asset_account MandatoryError) to /tmp.
# - Installs app without them.
# - Restores all (including skipped); suggests manual import-fixtures post-setup.
# Purpose: Bypasses validation errors during install; fixtures applied via migrate/manual command.
# Gotcha: If asset_category needed immediately, create manually in UI (Asset Category > New > Non-Depreciable).
# -----------------------------
# Workaround for mmcy_asset_management problematic fixtures
# -----------------------------
APP="mmcy_asset_management"
FIXTURE_DIR="apps/$APP/$APP/fixtures"
TEMP_FIXTURE_DIR="/tmp/${APP}_fixtures_backup"
echo "Temporarily removing problematic fixtures for $APP..."
mkdir -p "$TEMP_FIXTURE_DIR"
for f in account.json asset_category.json; do
    if [ -f "$FIXTURE_DIR/$f" ]; then
        echo "⏩ Skipping fixture: $f"
        mv "$FIXTURE_DIR/$f" "$TEMP_FIXTURE_DIR/"
    fi
done
bench --site "$SITE_NAME" install-app "$APP"
echo "Restoring fixture files..."
mv "$TEMP_FIXTURE_DIR"/* "$FIXTURE_DIR/" 2>/dev/null || true
rmdir "$TEMP_FIXTURE_DIR" 2>/dev/null || true

echo -e "${LIGHT_BLUE}⚠️ Skipped fixtures restored. Run this manually once setup is complete:${NC}"
echo "bench --site $SITE_NAME import-fixtures"

# Custom App Installation (mmcy_it_operations)
# - Straight install without workarounds (assumes no fixture issues).
# Purpose: Adds IT operations module.
# -----------------------------
# Install mmcy_it_operations
# -----------------------------
bench --site "$SITE_NAME" install-app mmcy_it_operations

# Migration for Schema and Fixtures
# - Runs bench migrate to apply all app updates, schemas, and restored fixtures to the DB.
# Purpose: Syncs everything post-install; essential for fixtures and patches.
# Run migrate to apply changes and fixtures
echo -e "${LIGHT_BLUE}Running migrate...${NC}"
bench --site "$SITE_NAME" migrate

# Asset Build
# - Compiles JS/CSS assets for the front-end.
# Purpose: Prepares UI; runs once after migrate.
echo -e "${LIGHT_BLUE}Running build...${NC}"
bench build

# Procfile Update for Web Server
# - Removes old web: lines; appends "web: bench serve --port 8003" for development server.
# Purpose: Configures bench start to use custom port; overrides defaults.
echo -e "${LIGHT_BLUE}Setting web port to $SITE_PORT in Procfile...${NC}"
sed -i '/^web:/d' Procfile || true
echo "web: bench serve --port $SITE_PORT" >> Procfile

# Hosts File Update
# - Checks/adds 127.0.0.1 mmcy.hrms to /etc/hosts if missing.
# Purpose: Enables http://mmcy.hrms:8003 access without DNS.
if ! grep -q "^127.0.0.1[[:space:]]\+$SITE_NAME\$" /etc/hosts; then
  echo "127.0.0.1 $SITE_NAME" | sudo tee -a /etc/hosts >/dev/null
fi

# Final Success Message
# - Prints completion and commands to start/serve the site.
# Purpose: Guides user to launch (bench start runs all services; serve for web only).
echo -e "${GREEN}Setup finished!${NC}"
echo -e " cd $INSTALL_DIR/$BENCH_NAME && bench start"
echo -e " cd $INSTALL_DIR/$BENCH_NAME && bench --site $SITE_NAME serve --port $SITE_PORT"


