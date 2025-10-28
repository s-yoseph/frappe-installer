#!/usr/bin/env bash
# install.sh - Simple Frappe + ERPNext + HRMS installer (Ubuntu / WSL)
# - No custom apps complexity
# - Just core Frappe, ERPNext, and HRMS
# - Simple and reliable
set -euo pipefail

### ===== CONFIG =====
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
BENCH_NAME="frappe-bench"
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="mmcy.hrms"
SITE_PORT="8003"
DB_PORT=3307
MYSQL_ROOT_PASS="root"
MYSQL_USER="frappe"
MYSQL_PASS="frappe"
ADMIN_PASS="admin"

### ===== COLORS =====
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${LIGHT_BLUE}Starting Frappe + ERPNext + HRMS installer...${NC}"
export PATH="$HOME/.local/bin:$PATH"

# Disable Python debugger
export PYTHONBREAKPOINT=0
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

### ===== Install system packages =====
echo -e "${LIGHT_BLUE}Installing dependencies...${NC}"
sudo apt update -y
sudo apt install -y python3-dev python3.12-venv python3-pip redis-server \
  software-properties-common mariadb-server mariadb-client xvfb libfontconfig wkhtmltopdf \
  curl git build-essential nodejs jq
sudo npm install -g yarn || true

### ===== MariaDB setup =====
echo -e "${LIGHT_BLUE}Setting up MariaDB on port ${DB_PORT}...${NC}"

MYSQL_DATA_DIR=/var/lib/mysql
MYSQL_RUN_DIR=/run/mysqld
LOG_DIR=/var/log/mysql

sudo mkdir -p "$LOG_DIR" "$MYSQL_RUN_DIR"
sudo touch "$LOG_DIR/error.log" "$LOG_DIR/slow.log" || true
sudo chown -R mysql:mysql "$LOG_DIR" "$MYSQL_RUN_DIR" "$MYSQL_DATA_DIR" || true
sudo chmod 750 "$MYSQL_DATA_DIR" || true

sudo systemctl stop mariadb || true
sleep 1

sudo tee /etc/mysql/mariadb.conf.d/99-custom-erpnext.cnf > /dev/null <<EOF
[mysqld]
port = ${DB_PORT}
socket = /run/mysqld/mysqld.sock
bind-address = 127.0.0.1
datadir = ${MYSQL_DATA_DIR}
skip-name-resolve
innodb_buffer_pool_size = 256M
log_error = ${LOG_DIR}/error.log
slow_query_log = 1
slow_query_log_file = ${LOG_DIR}/slow.log
EOF

echo -e "${LIGHT_BLUE}Starting MariaDB...${NC}"
sudo systemctl daemon-reload
sudo systemctl set-environment MYSQLD_OPTS="--skip-grant-tables"
sudo systemctl enable mariadb >/dev/null 2>&1 || true
sudo systemctl start mariadb
sleep 3

# Wait for MariaDB
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -e "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${GREEN}MariaDB is ready ✓${NC}"
    break
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

[ $ELAPSED -ge $TIMEOUT ] && die "MariaDB startup timeout"

# Set root password
mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

# Restart MariaDB normally
sudo systemctl stop mariadb
sleep 2
sudo systemctl unset-environment MYSQLD_OPTS
sudo systemctl start mariadb
sleep 3

# Verify connection
if ! mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT VERSION();" >/dev/null 2>&1; then
    die "Cannot login to MariaDB"
fi

echo -e "${GREEN}MariaDB configured ✓${NC}"

# Create frappe user
mysql --protocol=TCP -h 127.0.0.1 -P "${DB_PORT}" -u root -p"${MYSQL_ROOT_PASS}" <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

### ===== Install Bench =====
echo -e "${LIGHT_BLUE}Installing Bench CLI...${NC}"
if ! command -v pipx >/dev/null 2>&1; then
  sudo apt install -y pipx || true
  python3 -m pip install --user pipx || true
  python3 -m pipx ensurepath || true
fi

export PATH="$HOME/.local/bin:$PATH"

if ! command -v bench >/dev/null 2>&1; then
  pipx install frappe-bench --force || python3 -m pip install --user frappe-bench
fi

### ===== Initialize Bench =====
echo -e "${LIGHT_BLUE}Initializing Bench...${NC}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ ! -d "$BENCH_NAME" ]; then
  python3 -u $(which bench) init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 || die "bench init failed"
fi

cd "$BENCH_NAME"

# Configure bench
python3 -u $(which bench) config set-common-config -c db_host "'127.0.0.1'" || true
python3 -u $(which bench) config set-common-config -c db_port "${DB_PORT}" || true
python3 -u $(which bench) config set-common-config -c mariadb_root_password "'${MYSQL_ROOT_PASS}'" || true

### ===== Fetch Apps =====
echo -e "${LIGHT_BLUE}Fetching ERPNext and HRMS...${NC}"

[ ! -d "apps/erpnext" ] && python3 -u $(which bench) get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext || die "Failed to fetch ERPNext"
[ ! -d "apps/hrms" ] && python3 -u $(which bench) get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms || die "Failed to fetch HRMS"

echo -e "${GREEN}Apps fetched ✓${NC}"

### ===== Create Site =====
echo -e "${LIGHT_BLUE}Creating site '${SITE_NAME}'...${NC}"

python3 -u $(which bench) drop-site "${SITE_NAME}" --no-backup --force \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" 2>&1 | tail -3 || true

# Auto-continue through debugger if needed
(echo "c"; sleep 2) | python3 -u $(which bench) new-site "${SITE_NAME}" \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" \
  --no-interactive || die "Failed to create site"

echo -e "${GREEN}Site created ✓${NC}"

### ===== Install Apps =====
echo -e "${LIGHT_BLUE}Installing apps...${NC}"
python3 -u $(which bench) --site "${SITE_NAME}" install-app erpnext || die "Failed to install ERPNext"
python3 -u $(which bench) --site "${SITE_NAME}" install-app hrms || die "Failed to install HRMS"

echo -e "${GREEN}Apps installed ✓${NC}"

### ===== Done =====
echo -e "${GREEN}✓ Frappe setup completed!${NC}"
echo ""
echo "Access your site at: http://localhost:${SITE_PORT}"
echo "Admin password: ${ADMIN_PASS}"
echo ""
echo -e "${YELLOW}To start the development server:${NC}"
echo "cd ${INSTALL_DIR}/${BENCH_NAME} && bench start"
