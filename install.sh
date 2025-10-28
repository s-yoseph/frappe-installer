#!/usr/bin/env bash
# install.sh - Full corrected Frappe + ERPNext + custom apps installer (Ubuntu / WSL)
# - Automatically continues through Python debugger prompts
# - Disables all debugger interference
# - Fetches apps with proper error handling
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
MYSQL_ROOT_PASS="root"
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

# <CHANGE> Disable Python debugger completely
export PYTHONBREAKPOINT=0
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=utf-8

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

sudo npm install -g yarn || true

### ===== MariaDB setup (custom port + root password) =====
echo -e "${LIGHT_BLUE}Preparing MariaDB environment...${NC}"

MYSQL_DATA_DIR=/var/lib/mysql
MYSQL_RUN_DIR=/run/mysqld
MYSQL_SOCKET="/run/mysqld/mysqld.sock"
LOG_DIR=/var/log/mysql

sudo mkdir -p "$LOG_DIR" "$MYSQL_RUN_DIR"
sudo touch "$LOG_DIR/error.log" "$LOG_DIR/slow.log" || true
sudo chown -R mysql:mysql "$LOG_DIR" "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" || true
sudo chmod 750 "$MYSQL_DATA_DIR" || true

sudo systemctl stop mariadb || true
sleep 1

if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo cp /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf.bak || true
fi

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

echo -e "${LIGHT_BLUE}Starting MariaDB with --skip-grant-tables for initial setup...${NC}"
sudo systemctl daemon-reload
sudo systemctl set-environment MYSQLD_OPTS="--skip-grant-tables"
sudo systemctl enable mariadb >/dev/null 2>&1 || true
sudo systemctl start mariadb
sleep 3

echo "Waiting for MariaDB to start on port ${DB_PORT}..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -e "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${GREEN}MariaDB is ready ✓${NC}"
    break
  fi
  echo "Still waiting... ($ELAPSED/$TIMEOUT seconds)"
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo -e "${RED}MariaDB failed to start within ${TIMEOUT} seconds${NC}"
  echo "Debug info:"
  sudo journalctl -u mariadb -n 50 --no-pager || true
  sudo tail -n 50 "$LOG_DIR/error.log" || true
  die "MariaDB startup timeout"
fi

echo -e "${LIGHT_BLUE}Configuring MariaDB root user...${NC}"

mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

echo -e "${GREEN}Root password set.${NC}"

echo -e "${LIGHT_BLUE}Restarting MariaDB with normal authentication...${NC}"
sudo systemctl stop mariadb
sleep 2
sudo systemctl unset-environment MYSQLD_OPTS
sudo systemctl start mariadb
sleep 3

echo -e "${LIGHT_BLUE}Testing MariaDB root login on port ${DB_PORT}...${NC}"
if ! mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT VERSION();" >/dev/null 2>&1; then
    die "Cannot login to MariaDB root user with password. Check logs."
fi

echo -e "${GREEN}MariaDB root password verified on TCP.${NC}"

echo -e "${LIGHT_BLUE}Creating MariaDB user '${MYSQL_USER}'...${NC}"
mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

echo -e "${GREEN}MariaDB user configured.${NC}"

### ===== Bench CLI install =====
echo -e "${LIGHT_BLUE}Installing bench CLI (pipx/pip) and ensuring bench in PATH...${NC}"
if ! command -v pipx >/dev/null 2>&1; then
  sudo apt install -y pipx || true
  python3 -m pip install --user pipx || true
  python3 -m pipx ensurepath || true
fi

export PATH="$HOME/.local/bin:$PATH"

if ! command -v bench >/dev/null 2>&1; then
  pipx install frappe-bench --force || python3 -m pip install --user frappe-bench
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
if [ ! -d "$BENCH_NAME" ]; then
  echo -e "${LIGHT_BLUE}Initializing bench '${BENCH_NAME}' (frappe branch: ${FRAPPE_BRANCH})...${NC}"
  python3 -u $(which bench) init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 --verbose || die "bench init failed"
fi
cd "$BENCH_NAME"

echo -e "${LIGHT_BLUE}Configuring bench to use MariaDB on custom port...${NC}"
python3 -u $(which bench) config set-common-config -c db_host "'127.0.0.1'" || true
python3 -u $(which bench) config set-common-config -c db_port "${DB_PORT}" || true
python3 -u $(which bench) config set-common-config -c mariadb_root_password "'${MYSQL_ROOT_PASS}'" || true

### ===== Fetch apps =====
echo -e "${LIGHT_BLUE}Fetching ERPNext and HRMS apps...${NC}"

if [ ! -d "apps/erpnext" ]; then
  echo "Fetching ERPNext from GitHub..."
  if ! python3 -u $(which bench) get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext; then
    echo -e "${RED}Failed to fetch ERPNext${NC}"
    die "ERPNext is required for Frappe to work"
  fi
fi

if [ ! -d "apps/hrms" ]; then
  echo "Fetching HRMS from GitHub..."
  if ! python3 -u $(which bench) get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms; then
    echo -e "${RED}Failed to fetch HRMS${NC}"
    die "HRMS is required for Frappe to work"
  fi
fi

echo -e "${GREEN}Core apps fetched successfully.${NC}"

# Custom apps (optional)
if [ "${USE_LOCAL_APPS}" = "false" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  export GIT_TRACE=0
  [ ! -d "apps/mmcy_hrms" ] && python3 -u $(which bench) get-app --branch "$CUSTOM_BRANCH" mmcy_hrms "$CUSTOM_HR_REPO" || echo -e "${YELLOW}Custom HRMS fetch skipped${NC}"
  [ ! -d "apps/mmcy_asset_management" ] && python3 -u $(which bench) get-app --branch "$CUSTOM_BRANCH" mmcy_asset_management "$CUSTOM_ASSET_REPO" || echo -e "${YELLOW}Custom Asset fetch skipped${NC}"
  [ ! -d "apps/mmcy_it_operations" ] && python3 -u $(which bench) get-app --branch "$CUSTOM_BRANCH" mmcy_it_operations "$CUSTOM_IT_REPO" || echo -e "${YELLOW}Custom IT fetch skipped${NC}"
  unset GIT_TRACE
fi

### ===== Create site =====
echo -e "${LIGHT_BLUE}Creating site '${SITE_NAME}'...${NC}"
python3 -u $(which bench) drop-site "${SITE_NAME}" --no-backup --force \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" 2>&1 | tail -5 || true

# <CHANGE> Pipe "c" (continue) to automatically continue through debugger prompts
echo -e "${LIGHT_BLUE}Creating new site (auto-continuing through debugger if needed)...${NC}"
(echo "c"; sleep 2) | python3 -u $(which bench) new-site "${SITE_NAME}" \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" \
  --no-interactive || {
    echo -e "${RED}Failed to create site. Full debug info:${NC}"
    sudo journalctl -u mariadb -n 100 --no-pager || true
    tail -n 100 logs/* 2>/dev/null || true
    die "bench new-site failed"
  }

# Fix DB user ownership
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
  fi
fi

### ===== Install apps into site =====
echo -e "${LIGHT_BLUE}Installing apps into ${SITE_NAME}...${NC}"
python3 -u $(which bench) --site "${SITE_NAME}" install-app erpnext || echo -e "${YELLOW}ERPNext install skipped/warn${NC}"
python3 -u $(which bench) --site "${SITE_NAME}" install-app hrms || echo -e "${YELLOW}HRMS install skipped/warn${NC}"

if [ -d "apps/mmcy_hrms" ]; then
  python3 -u $(which bench) --site "${SITE_NAME}" install-app mmcy_hrms || echo -e "${YELLOW}Custom HRMS install skipped/warn${NC}"
fi
if [ -d "apps/mmcy_asset_management" ]; then
  python3 -u $(which bench) --site "${SITE_NAME}" install-app mmcy_asset_management || echo -e "${YELLOW}Custom Asset install skipped/warn${NC}"
fi
if [ -d "apps/mmcy_it_operations" ]; then
  python3 -u $(which bench) --site "${SITE_NAME}" install-app mmcy_it_operations || echo -e "${YELLOW}Custom IT install skipped/warn${NC}"
fi

echo -e "${GREEN}Frappe setup completed!${NC}"
echo "Access your site at: http://localhost:${SITE_PORT}"
echo -e "${YELLOW}To start the development server, run:${NC}"
echo "cd ${INSTALL_DIR}/${BENCH_NAME} && bench start"
