#!/usr/bin/env bash
set -euo pipefail

GITHUB_TOKEN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
BENCH_NAME="frappe-bench"
INSTALL_DIR="$HOME/frappe-setup"
SITE_NAME="mmcy.hrms"
SITE_PORT="8000"
DB_PORT="3307"
MYSQL_USER="frappe"
MYSQL_PASS="frappe"
ROOT_MYSQL_PASS="root"
ADMIN_PASS="admin"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

echo -e "${BLUE}Installing Frappe (Fresh Start)...${NC}"

# Install dependencies
sudo apt update -y
sudo apt install -y python3-dev python3.12-venv python3-pip redis-server mariadb-server mariadb-client curl git build-essential nodejs jq
sudo npm install -g yarn || true

# Setup MariaDB
echo -e "${BLUE}Setting up MariaDB...${NC}"
sudo systemctl stop mariadb || true
sleep 2

sudo tee /etc/mysql/mariadb.conf.d/99-custom.cnf > /dev/null <<EOF
[mysqld]
port = ${DB_PORT}
bind-address = 127.0.0.1
innodb_buffer_pool_size = 256M
skip-external-locking
EOF

sudo systemctl daemon-reload
sudo systemctl set-environment MYSQLD_OPTS="--skip-grant-tables"
sudo systemctl start mariadb
sleep 4

mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root <<SQL || die "Failed to set MariaDB root password"
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_MYSQL_PASS}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${ROOT_MYSQL_PASS}';
FLUSH PRIVILEGES;
SQL

sudo systemctl stop mariadb
sleep 2
sudo systemctl unset-environment MYSQLD_OPTS
sudo systemctl start mariadb
sleep 4

if ! mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${ROOT_MYSQL_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
  die "MariaDB connection failed - verify port ${DB_PORT} is accessible"
fi

echo -e "${GREEN}✓ MariaDB ready on port ${DB_PORT}${NC}"

# Install bench
if ! command -v bench >/dev/null 2>&1; then
  echo -e "${BLUE}Installing frappe-bench...${NC}"
  python3 -m pip install --user frappe-bench || die "Failed to install frappe-bench"
fi

echo -e "${BLUE}Cleaning up old installation...${NC}"
if [ -d "$INSTALL_DIR/$BENCH_NAME" ]; then
  echo "Removing old bench directory..."
  sudo chmod -R u+w "$INSTALL_DIR/$BENCH_NAME" 2>/dev/null || true
  sudo rm -rf "$INSTALL_DIR/$BENCH_NAME" || die "Failed to remove old bench directory"
  echo -e "${GREEN}Old bench removed${NC}"
fi

# Initialize bench fresh
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "${BLUE}Initializing fresh bench...${NC}"
bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 || die "Failed to initialize bench"

cd "$BENCH_NAME"

echo -e "${BLUE}Configuring bench...${NC}"
bench config set-common-config -c db_host "'127.0.0.1'" || true
bench config set-common-config -c db_port "${DB_PORT}" || true
bench config set-common-config -c mariadb_root_password "'${ROOT_MYSQL_PASS}'" || true

echo -e "${BLUE}Fetching apps...${NC}"

echo "Fetching ERPNext..."
bench get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext || die "Failed to get ERPNext"
echo -e "${GREEN}✓ ERPNext fetched and registered${NC}"

echo "Fetching HRMS..."
bench get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms || die "Failed to get HRMS"
echo -e "${GREEN}✓ HRMS fetched and registered${NC}"

if [ -z "${GITHUB_TOKEN}" ]; then
  echo -e "${YELLOW}⚠ No GitHub token provided - custom apps will be skipped${NC}"
  echo -e "${YELLOW}To include custom apps, run: curl -fsSL ... | bash -s -- -t YOUR_TOKEN${NC}"
else
  echo -e "${GREEN}✓ GitHub token received${NC}"

  echo "Fetching custom_hrms..."
  if GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom_hrms "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-hrms.git" 2>&1; then
    echo -e "${GREEN}✓ custom_hrms fetched and registered${NC}"
  else
    echo -e "${YELLOW}⚠ custom_hrms fetch failed (will continue)${NC}"
  fi

  echo "Fetching custom_asset_management..."
  if GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom_asset_management "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-asset-management.git" 2>&1; then
    echo -e "${GREEN}✓ custom_asset_management fetched and registered${NC}"
  else
    echo -e "${YELLOW}⚠ custom_asset_management fetch failed (will continue)${NC}"
  fi

  echo "Fetching custom_it_operations..."
  if GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom_it_operations "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-it-operations.git" 2>&1; then
    echo -e "${GREEN}✓ custom_it_operations fetched and registered${NC}"
  else
    echo -e "${YELLOW}⚠ custom_it_operations fetch failed (will continue)${NC}"
  fi
fi

echo -e "${GREEN}✓ All apps fetched${NC}"

echo -e "${BLUE}Available apps:${NC}"
bench list-apps

echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

echo "Cleaning up any leftover databases..."
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${ROOT_MYSQL_PASS}" <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS \`$(echo ${SITE_NAME} | sed 's/\./_/g')\`;
FLUSH PRIVILEGES;
SQL

rm -rf "sites/${SITE_NAME}" 2>/dev/null || true

sleep 5

bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${ROOT_MYSQL_PASS}" \
  --admin-password "${ADMIN_PASS}" || die "Failed to create site '${SITE_NAME}'"

echo -e "${GREEN}✓ Site created${NC}"

echo -e "${BLUE}Installing apps on site...${NC}"

bench --site "$SITE_NAME" install-app erpnext || die "ERPNext installation failed"
echo -e "${GREEN}✓ ERPNext installed${NC}"

bench --site "$SITE_NAME" install-app hrms || die "HRMS installation failed"
echo -e "${GREEN}✓ HRMS installed${NC}"

if [ -d "apps/custom_hrms" ]; then
  bench --site "$SITE_NAME" install-app custom_hrms || echo -e "${YELLOW}⚠ custom_hrms installation had issues${NC}"
  echo -e "${GREEN}✓ custom_hrms installed${NC}"
fi

if [ -d "apps/custom_asset_management" ]; then
  bench --site "$SITE_NAME" install-app custom_asset_management || echo -e "${YELLOW}⚠ custom_asset_management installation had issues${NC}"
  echo -e "${GREEN}✓ custom_asset_management installed${NC}"
fi

if [ -d "apps/custom_it_operations" ]; then
  bench --site "$SITE_NAME" install-app custom_it_operations || echo -e "${YELLOW}⚠ custom_it_operations installation had issues${NC}"
  echo -e "${GREEN}✓ custom_it_operations installed${NC}"
fi

echo -e "${BLUE}Running migrate...${NC}"
bench --site "$SITE_NAME" migrate || true

echo -e "${BLUE}Building assets...${NC}"
bench build || true

echo -e "${BLUE}Clearing cache...${NC}"
bench --site "$SITE_NAME" clear-cache || true
bench --site "$SITE_NAME" clear-website-cache || true

echo -e "${BLUE}Updating Procfile...${NC}"
sed -i '/^web:/d' Procfile || true
echo "web: bench serve --port $SITE_PORT" >> Procfile

# Add to hosts file
if ! grep -q "^127.0.0.1[[:space:]]\+$SITE_NAME\$" /etc/hosts; then
  echo "127.0.0.1 $SITE_NAME" | sudo tee -a /etc/hosts >/dev/null
  echo -e "${GREEN}✓ Added $SITE_NAME to /etc/hosts${NC}"
fi

echo -e "${BLUE}Verifying installed apps...${NC}"
bench --site "$SITE_NAME" list-apps

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Navigate to bench: cd ${INSTALL_DIR}/${BENCH_NAME}"
echo "2. Start the server: bench start"
echo "3. Access at: http://localhost:${SITE_PORT} or http://${SITE_NAME}:${SITE_PORT}"
echo ""
echo -e "${BLUE}Login credentials:${NC}"
echo "Site: ${SITE_NAME}"
echo "Admin Password: ${ADMIN_PASS}"
echo ""
echo -e "${BLUE}To use custom apps, run with GitHub token:${NC}"
echo "curl -fsSL https://your-script-url | bash -s -- -t YOUR_GITHUB_TOKEN"
