#!/usr/bin/env bash
# install.sh - Full corrected Frappe + ERPNext + custom apps installer (Ubuntu / WSL)
# - Fixes bench set-common-config quoting issue
# - Handles MariaDB root auth (unix_socket -> password)
# - Ensures logs/sockets exist and MariaDB runs on custom port
# - Fetches apps and creates a site
set -euo pipefail

### ===== CONFIG =====
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
BENCH_NAME="frappe-bench"
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="mmcy.hrms"
SITE_PORT="8003"
DB_PORT=3307
MYSQL_ROOT_PASS="root"          # change if you want another root password
MYSQL_USER="frappe"
MYSQL_PASS="frappe"
ADMIN_PASS="admin"
USE_LOCAL_APPS=false
CUSTOM_HR_REPO_BASE="github.com/MMCY-Tech/custom-hrms.git"
CUSTOM_ASSET_REPO_BASE="github.com/MMCY-Tech/custom-asset-management.git"
CUSTOM_IT_REPO_BASE="github.com/MMCY-Tech/custom-it-operations.git"

### ===== COLORS =====
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${LIGHT_BLUE}Starting full corrected install.sh...${NC}"
echo "Bench will be installed to: $INSTALL_DIR/$BENCH_NAME"
echo
export PATH="$HOME/.local/bin:$PATH"

# --- Helpers ---
die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

# --- Ask GitHub token only if needed for private repos
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -s -p "Enter your GitHub Personal Access Token (for private repos), or press Enter to skip: " GITHUB_TOKEN </dev/tty
    echo
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GITHUB_USER="token"
    CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
  else
    # Public fallback (no token)
    CUSTOM_HR_REPO="https://${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${CUSTOM_IT_REPO_BASE}"
  fi
fi

### ===== Install system packages =====
echo -e "${LIGHT_BLUE}Installing dependencies...${NC}"
sudo apt update -y
sudo apt install -y python3-dev python3.12-venv python3-pip redis-server \
  software-properties-common mariadb-server mariadb-client xvfb libfontconfig wkhtmltopdf \
  curl git build-essential nodejs jq

# make sure npm global binaries are usable
sudo npm install -g yarn || true

### ===== MariaDB setup (custom port + root password) =====
echo -e "${LIGHT_BLUE}Preparing MariaDB environment...${NC}"

MYSQL_DATA_DIR=/var/lib/mysql
MYSQL_RUN_DIR=/run/mysqld
MYSQL_SOCKET="/tmp/mysql_${DB_PORT}.sock"
LOG_DIR=/var/log/mysql

# Ensure log dir and files exist to avoid mariadb startup errors
sudo mkdir -p "$LOG_DIR" "$MYSQL_RUN_DIR"
sudo touch "$LOG_DIR/error.log" "$LOG_DIR/slow.log" || true
sudo chown -R mysql:mysql "$LOG_DIR" "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" || true
sudo chmod 750 "$MYSQL_DATA_DIR" || true

# Ensure mysql is stopped so we can set custom port cleanly
sudo systemctl stop mariadb || true
sleep 1

# Backup server conf if present
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo cp /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf.bak || true
fi

# Write custom conf to ensure port + socket
sudo tee /etc/mysql/mariadb.conf.d/99-custom-erpnext.cnf > /dev/null <<EOF
[mysqld]
port = ${DB_PORT}
socket = ${MYSQL_SOCKET}
bind-address = 127.0.0.1
datadir = ${MYSQL_DATA_DIR}
skip-name-resolve
innodb_buffer_pool_size = 256M
log_error = ${LOG_DIR}/error.log
slow_query_log = 1
slow_query_log_file = ${LOG_DIR}/slow.log
EOF

# Start MariaDB
sudo systemctl daemon-reload
sudo systemctl enable mariadb >/dev/null 2>&1 || true
sudo systemctl start mariadb

### ===== MariaDB setup =====
sudo systemctl stop mariadb || true
sudo systemctl start mariadb

# Wait for MariaDB via socket first (default)
echo "Waiting for MariaDB to start..."
until sudo mariadb -e "SELECT 1;" >/dev/null 2>&1; do
    sleep 2
done
echo "MariaDB is ready ✓"

echo -e "${LIGHT_BLUE}Configuring MariaDB root user...${NC}"

# Check current root auth plugin
current_plugin=$(sudo mariadb -sNe "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';")

if [ "$current_plugin" != "mysql_native_password" ]; then
  echo "Root user uses $current_plugin plugin, switching to mysql_native_password..."
  sudo mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASS}');
FLUSH PRIVILEGES;
SQL
else
  echo "Root user already uses mysql_native_password, skipping change."
fi

# Test connection with password on TCP
echo -e "${LIGHT_BLUE}Testing MariaDB root login on port ${DB_PORT}...${NC}"
if ! mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT VERSION();" >/dev/null 2>&1; then
    die "Cannot login to MariaDB root user. Check logs."
fi

echo -e "${GREEN}MariaDB root password set and verified.${NC}"

# Restart MariaDB to ensure port changes are applied
sudo systemctl restart mariadb
sleep 2

# Test TCP connection on custom port
if ! mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT VERSION();" >/dev/null 2>&1; then
    die "MariaDB root login failed. Check logs."
fi

echo -e "${GREEN}MariaDB root password set and tested.${NC}"

# Create frappe DB user (if not exists)
echo -e "${LIGHT_BLUE}Creating MariaDB user '${MYSQL_USER}'...${NC}"
# Use TCP connection if possible
mysql_cmd="mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p${MYSQL_ROOT_PASS}"
$mysql_cmd <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

echo -e "${GREEN}MariaDB user configured.${NC}"

### ===== Bench CLI install =====
echo -e "${LIGHT_BLUE}Installing bench CLI (pipx/pip) and ensuring bench in PATH...${NC}"
# Prefer pipx but fall back to pip if not present
if ! command -v pipx >/dev/null 2>&1; then
  sudo apt install -y pipx || true
  python3 -m pip install --user pipx || true
  python3 -m pipx ensurepath || true
fi

# Ensure pipx path in $PATH
export PATH="$HOME/.local/bin:$PATH"

# Use pip install --user if bench/pipx problems
if ! command -v bench >/dev/null 2>&1; then
  pipx install frappe-bench --force || python3 -m pip install --user frappe-bench
fi

# initialize bench
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
if [ ! -d "$BENCH_NAME" ]; then
  echo -e "${LIGHT_BLUE}Initializing bench '${BENCH_NAME}' (frappe branch: ${FRAPPE_BRANCH})...${NC}"
  bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 --verbose || die "bench init failed"
fi
cd "$BENCH_NAME"

# Fix benches' db_host quoting issue (the original bug)
echo -e "${LIGHT_BLUE}Configuring bench to use MariaDB on custom port...${NC}"
# Quote host value so bench's ast.literal_eval treats it as a string
bench config set-common-config -c db_host "'127.0.0.1'" || true
bench config set-common-config -c db_port "${DB_PORT}" || true

# Some bench versions need mariadb_root_password key to create/destroy sites; set it quoted
bench config set-common-config -c mariadb_root_password "'${MYSQL_ROOT_PASS}'" || true

### ===== Fetch apps =====
echo -e "${LIGHT_BLUE}Fetching ERPNext and HRMS apps...${NC}"
[ ! -d "apps/erpnext" ] && bench get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext || echo -e "${YELLOW}ERPNext fetch skipped or failed${NC}"
[ ! -d "apps/hrms" ] && bench get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms || echo -e "${YELLOW}HRMS fetch skipped or failed${NC}"

# Custom apps (use token if provided)
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  export GIT_TRACE=0
  [ ! -d "apps/mmcy_hrms" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_hrms "$CUSTOM_HR_REPO" || echo -e "${YELLOW}Custom HRMS fetch skipped${NC}"
  [ ! -d "apps/mmcy_asset_management" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_asset_management "$CUSTOM_ASSET_REPO" || echo -e "${YELLOW}Custom Asset fetch skipped${NC}"
  [ ! -d "apps/mmcy_it_operations" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_it_operations "$CUSTOM_IT_REPO" || echo -e "${YELLOW}Custom IT fetch skipped${NC}"
  unset GIT_TRACE
fi

### ===== Create site =====
echo -e "${LIGHT_BLUE}Creating site '${SITE_NAME}'...${NC}"
# Drop if exists (no backup) to make reruns idempotent
bench drop-site "${SITE_NAME}" --no-backup --force \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" || true

# Use bench new-site with TCP host/port
bench new-site "${SITE_NAME}" \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" || {
    echo -e "${RED}Failed to create site. Debug info:${NC}"
    sudo journalctl -u mariadb -n 80 --no-pager || true
    tail -n 80 logs/* || true
    die "bench new-site failed"
  }

# Fix DB user ownership (bench creates site DB user; ensure privileges)
SITE_CONF="sites/${SITE_NAME}/site_config.json"
if [ -f "$SITE_CONF" ]; then
  DB_NAME=$(jq -r '.db_name' "$SITE_CONF")
  DB_PWD=$(jq -r '.db_password' "$SITE_CONF")
  if [ -n "$DB_NAME" ] && [ -n "$DB_PWD" ]; then
    mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" <<SQL
DROP USER IF EXISTS '${DB_NAME}'@'localhost';
DROP USER IF EXISTS '${DB_NAME}'@'127.0.0.1';
CREATE USER '${DB_NAME}'@'localhost' IDENTIFIED BY '${DB_PWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'localhost';
CREATE USER '${DB_NAME}'@'127.0.0.1' IDENTIFIED BY '${DB_PWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    echo -e "${GREEN}Site DB user configured successfully.${NC}"
  else
    echo -e "${YELLOW}Could not parse site_config.json for DB credentials.${NC}"
  fi
fi

### ===== Install apps into site =====
echo -e "${LIGHT_BLUE}Installing apps into ${SITE_NAME} (if present)...${NC}"
bench --site "${SITE_NAME}" install-app erpnext || echo -e "${YELLOW}ERPNext install skipped/warn${NC}"
bench --site "${SITE_NAME}" install-app hrms || echo -e "${YELLOW}HRMS install skipped/warn${NC}"

if [ -d "apps/mmcy_hrms" ]; then
  bench --site "${SITE_NAME}" install-app mmcy_hrms || echo -e "${YELLOW}Custom HRMS install skipped/warn${NC}"
fi
if [ -d "apps/mmcy_asset_management" ]; then
  bench --site "${SITE_NAME}" install-app mmcy_asset_management || echo -e "${YELLOW}Custom Asset install skipped/warn${NC}"
fi
if [ -d "apps/mmcy_it_operations" ]; then
  bench --site "${SITE_NAME}" install-app mmcy_it_operations || echo -e "${YELLOW}Custom IT install skipped/warn${NC}"
fi

echo -e "${GREEN}Frappe setup completed!${NC}"
echo "Access your site at: http://localhost:${SITE_PORT}"
echo -e "${YELLOW}To start the development server, run:${NC}"
echo "cd ${INSTALL_DIR}/${BENCH_NAME} && bench start"
