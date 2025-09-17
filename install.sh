#!/usr/bin/env bash
# One-command Frappe v15 + ERPNext + HRMS + custom apps installer (local Ubuntu/WSL/Debian)
# - No Docker
# - Handles MariaDB issues on Ubuntu, WSL, and Debian
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

# Detect Environment (WSL or Debian/Ubuntu)
is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null || false
}

is_debian() {
  grep -qi "debian" /etc/os-release 2>/dev/null || false
}

WSL=false
DEBIAN=false
if is_wsl; then
  WSL=true
  echo -e "${YELLOW}Detected WSL environment. Using WSL-safe MariaDB logic.${NC}"
elif is_debian; then
  DEBIAN=true
  echo -e "${YELLOW}Detected Debian environment. Adjusting for Debian compatibility.${NC}"
else
  echo -e "${YELLOW}Detected Ubuntu or similar environment.${NC}"
fi

# Secure GitHub Token Handling
while getopts "t:" opt; do
  case $opt in
    t) GITHUB_TOKEN="$OPTARG" ;;
    *) echo "Usage: $0 [-t <github_token>]" >&2; exit 1 ;;
  esac
done
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -s -p "Enter your GitHub Personal Access Token (with repo read access): " GITHUB_TOKEN
    echo
  fi
  GITHUB_USER="token"
  CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
  CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
  CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
fi

# System Update and Core Packages
echo -e "${LIGHT_BLUE}Updating system and installing core packages...${NC}"
sudo apt update
sudo apt upgrade -y
sudo apt install -y git curl wget python3 python3-venv python3-dev python3-pip \
    redis-server xvfb libfontconfig wkhtmltopdf mariadb-server mariadb-client build-essential jq
if [ "$DEBIAN" = "true" ]; then
  sudo apt install -y libmariadb-dev
fi

# Node.js 18 and Yarn
echo -e "${LIGHT_BLUE}Installing Node.js 18 and yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
node -v && npm -v || true
sudo npm install -g yarn
yarn -v || true

# MariaDB Environment Preparation
echo -e "${LIGHT_BLUE}Preparing MariaDB environment...${NC}"
sudo mkdir -p /run/mysqld /var/lib/mysql /etc/mysql/conf.d
sudo chown -R mysql:mysql /run/mysqld /var/lib/mysql

DB_PORT=3306
MAX_PORT=3310
while [ $DB_PORT -le $MAX_PORT ]; do
  PORT_INFO="$(sudo ss -ltnp 2>/dev/null | grep -E ":$DB_PORT\\b" || true)"
  if [ -n "$PORT_INFO" ]; then
    PID="$(echo "$PORT_INFO" | awk '{print $6}' | sed -E 's/.*pid=([0-9]+),.*/\1/' || true)"
    if [ -n "$PID" ] && ps -p "$PID" -o comm= | grep -qiE "mysql|mariadbd|mysqld"; then
      if [ "$WSL" = "true" ] || [ "$DEBIAN" = "true" ]; then
        sudo service mariadb stop || true
      else
        sudo systemctl stop mariadb || true
      fi
      sleep 1
      if sudo ss -ltnp 2>/dev/null | grep -E ":$DB_PORT\\b" >/dev/null 2>&1; then
        sudo kill -9 "$PID" || true
        sleep 1
      fi
    else
      DB_PORT=$((DB_PORT + 1))
      continue
    fi
  fi
  break
done
echo -e "${GREEN}Using MariaDB port $DB_PORT.${NC}"

# MariaDB UTF-8 Configuration
sudo tee /etc/mysql/conf.d/frappe.cnf > /dev/null <<EOF
[mysqld]
port = $DB_PORT
socket = /run/mysqld/mysqld.sock
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

# MariaDB Root Password Setup
echo -e "${LIGHT_BLUE}Setting up MariaDB root password...${NC}"
sudo mysqladmin -u root password "$ROOT_MYSQL_PASS" 2>/dev/null || true
sudo mysql -u root -p"$ROOT_MYSQL_PASS" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_MYSQL_PASS';" 2>/dev/null || true
if [ "$WSL" = "true" ] || [ "$DEBIAN" = "true" ]; then
  sudo mysql_secure_installation --use-default || true
fi

# MariaDB Startup and Health Check
echo -e "${LIGHT_BLUE}Starting MariaDB...${NC}"
if [ "$WSL" = "true" ] || [ "$DEBIAN" = "true" ]; then
  for attempt in {1..3}; do
    sudo service mariadb start && break
    echo -e "${YELLOW}MariaDB start attempt $attempt failed, retrying...${NC}"
    sleep 2
  done || sudo /usr/sbin/mysqld --daemonize --port $DB_PORT || {
    echo -e "${RED}Failed to start MariaDB after retries.${NC}"
    sudo journalctl -xeu mariadb.service || true
    exit 1
  }
else
  sudo systemctl enable mariadb || {
    echo -e "${YELLOW}systemctl enable mariadb failed, trying service...${NC}"
    sudo service mariadb start
  }
  sudo systemctl restart mariadb || {
    echo -e "${YELLOW}systemctl restart mariadb failed, trying service...${NC}"
    sudo service mariadb start
  }
fi

i=0
MAX_WAIT=90
until mysql -u root -p"$ROOT_MYSQL_PASS" --port "$DB_PORT" --socket /run/mysqld/mysqld.sock -e "SELECT 1;" >/dev/null 2>&1; do
  sleep 1
  i=$((i+1))
  if [ $i -ge $MAX_WAIT ]; then
    echo -e "${RED}MariaDB did not start within ${MAX_WAIT}s.${NC}"
    sudo journalctl -xeu mariadb.service || true
    exit 1
  fi
done
echo -e "${GREEN}MariaDB is up.${NC}"

# MariaDB Bench User Creation
echo -e "${LIGHT_BLUE}Creating MariaDB bench user...${NC}"
sudo mysql -u root -p"$ROOT_MYSQL_PASS" --port "$DB_PORT" --socket /run/mysqld/mysqld.sock <<EOF
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASS';
GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Bench Installation
echo -e "${LIGHT_BLUE}Installing bench...${NC}"
python3 -m pip install --user --upgrade pip setuptools wheel
pip install --user frappe-bench

# Initialize Bench
echo -e "${LIGHT_BLUE}Initializing bench...${NC}"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
bench init --frappe-branch "$FRAPPE_BRANCH" --python "$(which python3)" "$BENCH_NAME"
cd "$BENCH_NAME"

# Install Apps
echo -e "${LIGHT_BLUE}Installing apps...${NC}"
if [ "${USE_LOCAL_APPS}" = "true" ]; then
  bench get-app --branch "$ERPNEXT_BRANCH" erpnext
  bench get-app --branch "$HRMS_BRANCH" hrms
  bench get-app mmcy_hrms ~/frappe-local/mmcy_hrms
  bench get-app mmcy_asset_management ~/frappe-local/mmcy_asset_management
  bench get-app mmcy_it_operations ~/frappe-local/mmcy_it_operations
else
  bench get-app --branch "$ERPNEXT_BRANCH" erpnext
  bench get-app --branch "$HRMS_BRANCH" hrms
  bench get-app mmcy_hrms "$CUSTOM_HR_REPO"
  bench get-app mmcy_asset_management "$CUSTOM_ASSET_REPO"
  bench get-app mmcy_it_operations "$CUSTOM_IT_REPO"
fi

# Create Site
echo -e "${LIGHT_BLUE}Creating site $SITE_NAME...${NC}"
bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host localhost \
  --db-port "$DB_PORT" \
  --db-name "$SITE_NAME" \
  --db-user "$MYSQL_USER" \
  --db-password "$MYSQL_PASS" \
  --admin-password "$ADMIN_PASS" \
  --no-mariadb-socket

# Install Apps on Site
echo -e "${LIGHT_BLUE}Installing apps on site...${NC}"
bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms
bench --site "$SITE_NAME" install-app mmcy_hrms
bench --site "$SITE_NAME" install-app mmcy_asset_management
bench --site "$SITE_NAME" install-app mmcy_it_operations

# Workaround for Fixture Errors
echo -e "${LIGHT_BLUE}Applying fixture workarounds...${NC}"
bench --site "$SITE_NAME" migrate --skip-failing
echo -e "${YELLOW}If fixtures are needed, run 'bench --site $SITE_NAME import-fixtures' after setup.${NC}"

# Configure Site Port
echo -e "${LIGHT_BLUE}Configuring site port...${NC}"
bench set-config -g port "$SITE_PORT"

# Setup Complete
echo -e "${GREEN}Setup finished!${NC}"
echo -e "To start the site:"
echo -e "  cd $INSTALL_DIR/$BENCH_NAME"
echo -e "  bench start"
echo -e "Access at: http://$SITE_NAME:$SITE_PORT (login: admin/$ADMIN_PASS)"
echo -e "To import fixtures (if needed):"
echo -e "  bench --site $SITE_NAME import-fixtures"
