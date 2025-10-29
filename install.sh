#!/usr/bin/env bash
set -euo pipefail

FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
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
  # First try to fix permissions recursively
  sudo chmod -R u+w "$INSTALL_DIR/$BENCH_NAME" 2>/dev/null || true
  # Then remove
  sudo rm -rf "$INSTALL_DIR/$BENCH_NAME" || die "Failed to remove old bench directory"
  echo -e "${GREEN}Old bench removed${NC}"
fi

# Initialize bench fresh
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "${BLUE}Initializing fresh bench...${NC}"
bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 || die "Failed to initialize bench"

cd "$BENCH_NAME"

echo -e "${BLUE}Creating clean apps configuration...${NC}"
cat > apps.txt <<EOF
frappe
erpnext
hrms
EOF

echo -e "${BLUE}Configuring bench...${NC}"
bench config set-common-config -c db_host "'127.0.0.1'" || true
bench config set-common-config -c db_port "${DB_PORT}" || true
bench config set-common-config -c mariadb_root_password "'${MYSQL_ROOT_PASS}'" || true

echo -e "${BLUE}Fetching apps...${NC}"

if [ ! -d "apps/erpnext" ]; then
  echo "Fetching ERPNext from branch ${ERPNEXT_BRANCH}..."
  git clone --branch "$ERPNEXT_BRANCH" https://github.com/frappe/erpnext.git apps/erpnext || die "Failed to fetch ERPNext"
  echo -e "${GREEN}✓ ERPNext fetched${NC}"
fi

if [ ! -d "apps/hrms" ]; then
  echo "Fetching HRMS from branch ${HRMS_BRANCH}..."
  git clone --branch "$HRMS_BRANCH" https://github.com/frappe/hrms.git apps/hrms || die "Failed to fetch HRMS"
  echo -e "${GREEN}✓ HRMS fetched${NC}"
fi

echo -e "${GREEN}✓ All apps fetched${NC}"

echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

# Try to drop existing site (ignore errors)
bench drop-site "$SITE_NAME" --no-backup --force --db-root-username root --db-root-password "${MYSQL_ROOT_PASS}" 2>&1 | tail -3 || true

# Create new site
(echo "c"; sleep 2) | bench new-site "$SITE_NAME" \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" \
  --no-interactive || die "Failed to create site '${SITE_NAME}'"

echo -e "${GREEN}✓ Site created${NC}"

echo -e "${BLUE}Installing apps...${NC}"

if bench --site "$SITE_NAME" install-app erpnext; then
  echo -e "${GREEN}✓ ERPNext installed${NC}"
else
  echo -e "${YELLOW}⚠ ERPNext installation had issues (may be normal)${NC}"
fi

if bench --site "$SITE_NAME" install-app hrms; then
  echo -e "${GREEN}✓ HRMS installed${NC}"
else
  echo -e "${YELLOW}⚠ HRMS installation had issues (may be normal)${NC}"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Navigate to bench: cd ${INSTALL_DIR}/${BENCH_NAME}"
echo "2. Start the server: bench start"
echo "3. Access at: http://localhost:8000"
echo ""
echo -e "${BLUE}Login credentials:${NC}"
echo "Site: ${SITE_NAME}"
echo "Admin Password: ${ADMIN_PASS}"
echo ""
