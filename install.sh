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
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="mmcy.hrms"
DB_PORT=3307
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"

export PYTHONBREAKPOINT=0
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PATH="$HOME/.local/bin:$PATH"

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
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

sudo systemctl stop mariadb
sleep 2
sudo systemctl unset-environment MYSQLD_OPTS
sudo systemctl start mariadb
sleep 4

if ! mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
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
bench config set-common-config -c mariadb_root_password "'${MYSQL_ROOT_PASS}'" || true

echo -e "${BLUE}Fetching apps...${NC}"

echo "Fetching ERPNext from branch ${ERPNEXT_BRANCH}..."
bench get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext || die "Failed to get ERPNext"
echo -e "${GREEN}✓ ERPNext fetched${NC}"

echo "Fetching HRMS from branch ${HRMS_BRANCH}..."
bench get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms || die "Failed to get HRMS"
echo -e "${GREEN}✓ HRMS fetched${NC}"

if [ -z "${GITHUB_TOKEN}" ]; then
  echo -e "${YELLOW}⚠ No GitHub token provided - custom apps will be skipped${NC}"
  echo -e "${YELLOW}To include custom apps, run: bash install-frappe.sh -t YOUR_GITHUB_TOKEN${NC}"
else
  echo -e "${GREEN}✓ GitHub token received${NC}"

  echo "Fetching custom-hrms from branch ${CUSTOM_BRANCH}..."
  if GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom-hrms "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-hrms.git" 2>&1; then
    echo -e "${GREEN}✓ custom-hrms fetched${NC}"
  else
    echo -e "${YELLOW}⚠ custom-hrms fetch failed${NC}"
  fi

  echo "Fetching custom-asset-management from branch ${CUSTOM_BRANCH}..."
  if GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom-asset-management "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-asset-management.git" 2>&1; then
    echo -e "${GREEN}✓ custom-asset-management fetched${NC}"
  else
    echo -e "${YELLOW}⚠ custom-asset-management fetch failed${NC}"
  fi

  echo "Fetching custom-it-operations from branch ${CUSTOM_BRANCH}..."
  if GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom-it-operations "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-it-operations.git" 2>&1; then
    echo -e "${GREEN}✓ custom-it-operations fetched${NC}"
  else
    echo -e "${YELLOW}⚠ custom-it-operations fetch failed${NC}"
  fi
fi

echo -e "${GREEN}✓ All apps fetched${NC}"

echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

echo "Cleaning up any leftover databases..."
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS \`$(echo ${SITE_NAME} | sed 's/\./_/g')\`;
DROP DATABASE IF EXISTS \`_afd6259a990fe66d\`;
FLUSH PRIVILEGES;
SQL

rm -rf "sites/${SITE_NAME}" 2>/dev/null || true

bench drop-site "$SITE_NAME" --no-backup --force --db-root-username root --db-root-password "${MYSQL_ROOT_PASS}" 2>&1 | tail -3 || true

bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" || die "Failed to create site '${SITE_NAME}'"

echo -e "${GREEN}✓ Site created${NC}"

echo -e "${BLUE}Installing apps on site...${NC}"

echo "Installing ERPNext..."
bench --site "$SITE_NAME" install-app erpnext || die "Failed to install ERPNext"
echo -e "${GREEN}✓ ERPNext installed${NC}"

echo "Installing HRMS..."
bench --site "$SITE_NAME" install-app hrms || die "Failed to install HRMS"
echo -e "${GREEN}✓ HRMS installed${NC}"

if [ -d "apps/custom-hrms" ]; then
  echo "Installing custom-hrms..."
  bench --site "$SITE_NAME" install-app custom-hrms || echo -e "${YELLOW}⚠ custom-hrms installation had issues${NC}"
  echo -e "${GREEN}✓ custom-hrms processed${NC}"
fi

if [ -d "apps/custom-asset-management" ]; then
  echo "Installing custom-asset-management..."
  bench --site "$SITE_NAME" install-app custom-asset-management || echo -e "${YELLOW}⚠ custom-asset-management installation had issues${NC}"
  echo -e "${GREEN}✓ custom-asset-management processed${NC}"
fi

if [ -d "apps/custom-it-operations" ]; then
  echo "Installing custom-it-operations..."
  bench --site "$SITE_NAME" install-app custom-it-operations || echo -e "${YELLOW}⚠ custom-it-operations installation had issues${NC}"
  echo -e "${GREEN}✓ custom-it-operations processed${NC}"
fi

echo -e "${BLUE}Running migrate...${NC}"
bench --site "$SITE_NAME" migrate || true

echo -e "${BLUE}Building assets and clearing cache...${NC}"
bench build || true
bench --site "$SITE_NAME" clear-cache || true
bench --site "$SITE_NAME" clear-website-cache || true

echo -e "${BLUE}Verifying installed apps...${NC}"
bench --site "$SITE_NAME" list-apps

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Navigate to bench: cd ${INSTALL_DIR}/${BENCH_NAME}"
echo "2. Start the server: bench start"
echo "3. Access at: http://localhost:8000 or http://${SITE_NAME}:8000"
echo ""
echo -e "${BLUE}Login credentials:${NC}"
echo "Site: ${SITE_NAME}"
echo "Admin Password: ${ADMIN_PASS}"
echo ""
echo -e "${BLUE}Installed apps:${NC}"
echo "  - frappe (core framework)"
echo "  - erpnext (ERP system)"
echo "  - hrms (HR module)"
echo "  - custom-hrms (your custom HRMS)"
echo "  - custom-asset-management (your custom asset management)"
echo "  - custom-it-operations (your custom IT operations)"
echo ""
