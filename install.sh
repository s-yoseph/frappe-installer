#!/usr/bin/env bash
# One-command Frappe v15 + ERPNext + HRMS + custom apps installer (local Ubuntu/WSL)
set -euo pipefail

### ===== CONFIG =====
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
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${LIGHT_BLUE}Starting one-command Frappe v15 setup...${NC}"
echo "Bench will be installed to: $INSTALL_DIR/$BENCH_NAME"
echo
export PATH="$HOME/.local/bin:$PATH"

# WSL Detection Function and Check
is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null || false
}
WSL=false
if is_wsl; then
  WSL=true
  echo -e "${YELLOW}Detected WSL environment. Will use WSL-safe MariaDB logic.${NC}"
fi

if $WSL; then
  if ! pidof systemd >/dev/null; then
    echo -e "${RED}Systemd is not running in WSL, which is required for reliable MariaDB management.${NC}"
    echo "To enable it, add this to /etc/wsl.conf (create if missing):"
    echo "[boot]"
    echo "systemd=true"
    echo "Save, then from Windows PowerShell: wsl --shutdown"
    echo "Relaunch your WSL terminal and rerun this script."
    exit 1
  fi
  echo -e "${GREEN}Systemd detected in WSL. Proceeding with systemctl for MariaDB.${NC}"
fi

# Secure GitHub Token Handling for Custom Apps
if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -s -p "Enter your GitHub Personal Access Token (with repo read access): " GITHUB_TOKEN </dev/tty
    echo
fi

if [ "${USE_LOCAL_APPS:-false}" = "false" ]; then
  GITHUB_USER="token"
  CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
  CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
  CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
fi

# System Update and Core Package Installation
echo -e "${LIGHT_BLUE}Updating system and installing core packages...${NC}"
sudo apt update
sudo apt upgrade -y
sudo apt install -y git curl wget python3 python3-venv python3-dev python3-pip \
    redis-server xvfb libfontconfig wkhtmltopdf build-essential jq

# Node.js 18 and Yarn Installation
echo -e "${LIGHT_BLUE}Installing Node.js 18 and yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
node -v && npm -v || true
sudo npm install -g yarn
yarn -v || true

### ===== MariaDB Setup =====
echo -e "${LIGHT_BLUE}Preparing MariaDB environment...${NC}"
MYSQL_DATA_DIR=/var/lib/mysql
MYSQL_RUN_DIR=/run/mysqld
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"
DB_PORT=3307

sudo mkdir -p "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" /var/log/mysql /etc/mysql/conf.d
sudo chown -R mysql:mysql "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" /var/log/mysql
sudo chmod 750 "$MYSQL_DATA_DIR"
sudo chmod 755 "$MYSQL_RUN_DIR"
sudo chmod 755 /etc/mysql/conf.d

echo -e "${YELLOW}Stopping any existing MariaDB/MySQL services...${NC}"
sudo systemctl stop mariadb mysql >/dev/null 2>&1 || true
sudo systemctl stop mysqld >/dev/null 2>&1 || true

for port in 3306 3307; do
  if ss -ltn | grep -q ":$port "; then
    echo -e "${YELLOW}Killing processes on port $port...${NC}"
    sudo fuser -k $port/tcp 2>/dev/null || true
    sleep 1
  fi
done

sudo killall -9 mysqld mariadbd mysqld_safe mysql 2>/dev/null || true
sleep 2

sudo rm -f "$MYSQL_SOCKET" /var/lib/mysql/*.pid /var/lib/mysql/*.sock /var/lib/mysql/*.lock /tmp/mariadb.log 2>/dev/null || true
sudo rm -rf /var/run/mysqld/* 2>/dev/null || true

if ! command -v mariadbd >/dev/null 2>&1 && ! command -v mysqld >/dev/null 2>&1; then
  echo -e "${RED}MariaDB server binary not found. Installation may be incomplete.${NC}"
  echo "Try: sudo apt install --reinstall mariadb-server"
  exit 1
fi

if [ -d "$MYSQL_DATA_DIR" ]; then
  sudo chown -R mysql:mysql "$MYSQL_DATA_DIR"
  sudo chmod 750 "$MYSQL_DATA_DIR"
fi

if [ ! -d "$MYSQL_DATA_DIR/mysql" ] || [ -z "$(ls -A "$MYSQL_DATA_DIR" 2>/dev/null)" ]; then
  echo -e "${YELLOW}Initializing MariaDB system tables (first time)...${NC}"
  if command -v mariadb-install-db >/dev/null 2>&1; then
    sudo mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
  else
    sudo mysql_install_db --user=mysql --datadir="$MYSQL_DATA_DIR" >/tmp/mariadb.log 2>&1 || true
  fi
fi

echo -e "${YELLOW}Writing MariaDB configuration for port $DB_PORT...${NC}"
sudo tee /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
datadir = $MYSQL_DATA_DIR
port = $DB_PORT
socket = $MYSQL_SOCKET
bind-address = 127.0.0.1
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-host-cache
skip-name-resolve
max_connections = 500
innodb_buffer_pool_size = 256M
log_error = /var/log/mysql/error.log
[mysql]
default-character-set = utf8mb4
socket = $MYSQL_SOCKET
EOF

echo -e "${LIGHT_BLUE}Enabling and starting MariaDB service...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable mariadb >/dev/null 2>&1 || true

if ! sudo systemctl start mariadb 2>&1; then
  echo -e "${RED}Failed to start MariaDB. Checking logs...${NC}"
  sudo journalctl -u mariadb -n 50 --no-pager || true
  sudo tail -50 /var/log/mysql/error.log 2>/dev/null || true
  exit 1
fi

echo -n "Waiting for MariaDB to accept connections"
for i in {1..120}; do
  if sudo mysql --socket="$MYSQL_SOCKET" -e "SELECT 1;" >/dev/null 2>&1; then
    echo " ✓"
    echo -e "${GREEN}MariaDB is up and reachable on port $DB_PORT.${NC}"
    break
  fi
  echo -n "."
  sleep 1
  if [ $i -eq 120 ]; then
    echo
    echo -e "${RED}MariaDB did not start within 120 seconds.${NC}"
    sudo systemctl status mariadb --no-pager || true
    sudo journalctl -u mariadb -n 50 --no-pager || true
    exit 1
  fi
done

echo -e "${LIGHT_BLUE}Configuring MariaDB users...${NC}"
sudo mysql --socket="$MYSQL_SOCKET" <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_MYSQL_PASS';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS \`${MYSQL_USER}\`;
FLUSH PRIVILEGES;
SQL

if [ $? -eq 0 ]; then
  echo -e "${GREEN}MariaDB users configured successfully.${NC}"
else
  echo -e "${RED}Failed to configure MariaDB users.${NC}"
  exit 1
fi

### ===== End MariaDB Setup =====

# Frappe Bench CLI Installation
echo -e "${LIGHT_BLUE}Installing frappe-bench CLI...${NC}"
sudo apt install pipx -y
rm -f ~/.local/bin/bench
pipx install frappe-bench --force
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

# Bench Initialization
echo -e "${LIGHT_BLUE}Initializing bench...${NC}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
if [ ! -d "$BENCH_NAME" ]; then
  bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --verbose
fi
cd "$BENCH_NAME"

echo -e "${LIGHT_BLUE}Configuring bench for custom MariaDB port...${NC}"
bench config set-common-config -c db_host "'127.0.0.1'" || true
bench config set-common-config -c db_port $DB_PORT || true

# Fetching Core Apps
echo -e "${LIGHT_BLUE}Fetching ERPNext and HRMS apps...${NC}"
[ ! -d "apps/erpnext" ] && bench get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext || echo -e "${RED}Failed to fetch ERPNext${NC}"
[ ! -d "apps/hrms" ] && bench get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms || echo -e "${RED}Failed to fetch HRMS${NC}"

# Fetching Custom Apps
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  export GIT_TRACE=0
  [ ! -d "apps/mmcy_hrms" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_hrms "$CUSTOM_HR_REPO" 2>/dev/null || echo -e "${RED}Failed to fetch custom HRMS${NC}"
  [ ! -d "apps/mmcy_asset_management" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_asset_management "$CUSTOM_ASSET_REPO" 2>/dev/null || echo -e "${RED}Failed to fetch custom Asset Management${NC}"
  [ ! -d "apps/mmcy_it_operations" ] && bench get-app --branch "$CUSTOM_BRANCH" mmcy_it_operations "$CUSTOM_IT_REPO" 2>/dev/null || echo -e "${RED}Failed to fetch custom IT Operations${NC}"
  unset GIT_TRACE
fi

# Site Creation
echo -e "${LIGHT_BLUE}Creating site ${SITE_NAME}...${NC}"
bench drop-site "$SITE_NAME" --no-backup --force \
  --db-root-username root \
  --db-root-password "$ROOT_MYSQL_PASS" || true

bench new-site "$SITE_NAME" \
  --db-host "127.0.0.1" \
  --db-port "$DB_PORT" \
  --db-root-username root \
  --db-root-password "$ROOT_MYSQL_PASS" \
  --admin-password "$ADMIN_PASS" || {
  echo -e "${RED}Failed to create site. Checking MariaDB connection...${NC}"
  sudo mysql --socket="$MYSQL_SOCKET" -u root -p"$ROOT_MYSQL_PASS" -e "SELECT 1;" || exit 1
  exit 1
}

# Site-Specific DB User Fix
echo -e "${LIGHT_BLUE}Configuring site database user...${NC}"
DB_NAME=$(jq -r '.db_name' "sites/${SITE_NAME}/site_config.json" 2>/dev/null || echo "")
DB_PWD=$(jq -r '.db_password' "sites/${SITE_NAME}/site_config.json" 2>/dev/null || echo "")

if [ -z "$DB_NAME" ] || [ -z "$DB_PWD" ]; then
  echo -e "${RED}Failed to extract database credentials from site config.${NC}"
  exit 1
fi

sudo mysql --socket="$MYSQL_SOCKET" -u root -p"$ROOT_MYSQL_PASS" <<SQL
DROP USER IF EXISTS '${DB_NAME}'@'localhost';
DROP USER IF EXISTS '${DB_NAME}'@'127.0.0.1';
CREATE USER '${DB_NAME}'@'localhost' IDENTIFIED BY '${DB_PWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'localhost';
CREATE USER '${DB_NAME}'@'127.0.0.1' IDENTIFIED BY '${DB_PWD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

if [ $? -eq 0 ]; then
  echo -e "${GREEN}Site DB user configured successfully.${NC}"
else
  echo -e "${RED}Failed to configure site database user.${NC}"
  exit 1
fi

# Core App Installation
echo -e "${LIGHT_BLUE}Installing apps into ${SITE_NAME}...${NC}"
bench --site "$SITE_NAME" install-app erpnext || echo -e "${RED}Warning: Failed to install ERPNext${NC}"
bench --site "$SITE_NAME" install-app hrms || echo -e "${RED}Warning: Failed to install HRMS${NC}"

if [ -d "apps/mmcy_hrms" ]; then
  bench --site "$SITE_NAME" install-app mmcy_hrms || echo -e "${RED}Warning: Failed to install custom HRMS${NC}"
fi
if [ -d "apps/mmcy_asset_management" ]; then
  bench --site "$SITE_NAME" install-app mmcy_asset_management || echo -e "${RED}Warning: Failed to install custom Asset Management${NC}"
fi
if [ -d "apps/mmcy_it_operations" ]; then
  bench --site "$SITE_NAME" install-app mmcy_it_operations || echo -e "${RED}Warning: Failed to install custom IT Operations${NC}"
fi

echo -e "${GREEN}Frappe setup completed successfully!${NC}"
echo "Access your site at: http://localhost:${SITE_PORT}"
echo -e "${YELLOW}To start the development server, run:${NC}"
echo "cd $INSTALL_DIR/$BENCH_NAME && bench start"
