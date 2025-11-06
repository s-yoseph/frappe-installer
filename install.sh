#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIGURATION ==================
GITHUB_TOKEN=""
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
BENCH_NAME="frappe-bench"
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="hrms.mmcy"
DB_PORT=3307
REDIS_CACHE_PORT=11000
REDIS_QUEUE_PORT=12000
REDIS_SOCKETIO_PORT=13000
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"

# Parse command line arguments
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

# ================== SETUP ==================
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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}MMCY HRMS Complete Installation${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Configuration:${NC}"
echo "  Bench Name: ${BENCH_NAME}"
echo "  Frappe Branch: ${FRAPPE_BRANCH}"
echo "  Site Name: ${SITE_NAME}"
echo "  Total Apps to Install: 5"
echo ""

# ================== INSTALL DEPENDENCIES ==================
echo -e "${BLUE}Installing system dependencies...${NC}"
sudo apt update -y
sudo apt install -y python3-dev python3.12-venv python3-pip redis-server mariadb-server mariadb-client curl git build-essential nodejs jq
sudo npm install -g yarn || true

# ================== SETUP REDIS ==================
echo -e "${BLUE}Setting up Redis instances...${NC}"
sudo pkill -9 -f redis-server 2>/dev/null || true
sudo fuser -k ${REDIS_CACHE_PORT}/tcp 2>/dev/null || true
sudo fuser -k ${REDIS_QUEUE_PORT}/tcp 2>/dev/null || true
sudo fuser -k ${REDIS_SOCKETIO_PORT}/tcp 2>/dev/null || true
sleep 2

REDIS_CONFIG_DIR="${HOME}/.redis"
mkdir -p "$REDIS_CONFIG_DIR"
sudo systemctl stop redis-server || true
sleep 2

# Configure Redis cache
cat > "$REDIS_CONFIG_DIR/redis-cache.conf" <<EOF
port ${REDIS_CACHE_PORT}
bind 127.0.0.1
daemonize no
pidfile ${REDIS_CONFIG_DIR}/redis-cache.pid
loglevel notice
databases 16
rdbcompression yes
dbfilename dump-cache.rdb
dir ${REDIS_CONFIG_DIR}
appendonly no
EOF

# Configure Redis queue
cat > "$REDIS_CONFIG_DIR/redis-queue.conf" <<EOF
port ${REDIS_QUEUE_PORT}
bind 127.0.0.1
daemonize no
pidfile ${REDIS_CONFIG_DIR}/redis-queue.pid
loglevel notice
databases 16
rdbcompression yes
dbfilename dump-queue.rdb
dir ${REDIS_CONFIG_DIR}
appendonly no
EOF

# Configure Redis socketio
cat > "$REDIS_CONFIG_DIR/redis-socketio.conf" <<EOF
port ${REDIS_SOCKETIO_PORT}
bind 127.0.0.1
daemonize no
pidfile ${REDIS_CONFIG_DIR}/redis-socketio.pid
loglevel notice
databases 16
rdbcompression yes
dbfilename dump-socketio.rdb
dir ${REDIS_CONFIG_DIR}
appendonly no
EOF

# Start Redis instances
redis-server "$REDIS_CONFIG_DIR/redis-cache.conf" &
sleep 2
redis-server "$REDIS_CONFIG_DIR/redis-queue.conf" &
sleep 2
redis-server "$REDIS_CONFIG_DIR/redis-socketio.conf" &
sleep 2

# Verify Redis
for i in {1..30}; do
  if redis-cli -p ${REDIS_CACHE_PORT} ping >/dev/null 2>&1 && \
     redis-cli -p ${REDIS_QUEUE_PORT} ping >/dev/null 2>&1 && \
     redis-cli -p ${REDIS_SOCKETIO_PORT} ping >/dev/null 2>&1; then
    echo -e "${GREEN}✓ All Redis instances running${NC}"
    break
  fi
  [ $i -eq 30 ] && die "Redis failed to start"
  sleep 1
done

# ================== SETUP MARIADB ==================
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

mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1 || die "MariaDB connection failed"
echo -e "${GREEN}✓ MariaDB ready on port ${DB_PORT}${NC}"

# ================== INSTALL BENCH ==================
echo -e "${BLUE}Installing frappe-bench...${NC}"
command -v bench >/dev/null 2>&1 || python3 -m pip install --user frappe-bench || die "Failed to install frappe-bench"

# ================== INITIALIZE BENCH ==================
echo -e "${BLUE}Cleaning up old installation...${NC}"
if [ -d "$INSTALL_DIR/$BENCH_NAME" ]; then
  sudo chmod -R u+w "$INSTALL_DIR/$BENCH_NAME" 2>/dev/null || true
  sudo rm -rf "$INSTALL_DIR/$BENCH_NAME" || die "Failed to remove old bench"
  echo -e "${GREEN}Old installation removed${NC}"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "${BLUE}Initializing bench...${NC}"
bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python python3 || die "Failed to initialize bench"
cd "$BENCH_NAME"

# ================== CONFIGURE BENCH ==================
echo -e "${BLUE}Configuring bench...${NC}"
bench config set-common-config -c db_host "'127.0.0.1'" || true
bench config set-common-config -c db_port "${DB_PORT}" || true
bench config set-common-config -c mariadb_root_password "'${MYSQL_ROOT_PASS}'" || true
bench config set-common-config -c redis_cache "'redis://127.0.0.1:${REDIS_CACHE_PORT}'" || true
bench config set-common-config -c redis_queue "'redis://127.0.0.1:${REDIS_QUEUE_PORT}'" || true
bench config set-common-config -c redis_socketio "'redis://127.0.0.1:${REDIS_SOCKETIO_PORT}'" || true

# ================== FETCH APPS ==================
echo -e "${BLUE}Fetching apps...${NC}"

echo "→ ERPNext (${ERPNEXT_BRANCH})..."
bench get-app --branch "$ERPNEXT_BRANCH" erpnext https://github.com/frappe/erpnext || die "Failed to get ERPNext"
echo -e "${GREEN}✓ ERPNext${NC}"

echo "→ HRMS (${HRMS_BRANCH})..."
bench get-app --branch "$HRMS_BRANCH" hrms https://github.com/frappe/hrms || die "Failed to get HRMS"
echo -e "${GREEN}✓ HRMS${NC}"

if [ -z "${GITHUB_TOKEN}" ]; then
  echo -e "${YELLOW}⚠ No GitHub token - custom apps will be skipped${NC}"
  echo -e "${YELLOW}Rerun with: bash $0 -t YOUR_GITHUB_TOKEN${NC}"
else
  echo "→ custom-hrms (${CUSTOM_BRANCH})..."
  GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom-hrms "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-hrms.git" 2>&1 && echo -e "${GREEN}✓ custom-hrms${NC}" || echo -e "${YELLOW}⚠ custom-hrms fetch failed${NC}"

  echo "→ custom-asset-management (${CUSTOM_BRANCH})..."
  GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom-asset-management "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-asset-management.git" 2>&1 && echo -e "${GREEN}✓ custom-asset-management${NC}" || echo -e "${YELLOW}⚠ custom-asset-management fetch failed${NC}"

  echo "→ custom-it-operations (${CUSTOM_BRANCH})..."
  GIT_TERMINAL_PROMPT=0 bench get-app --branch "$CUSTOM_BRANCH" custom-it-operations "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-it-operations.git" 2>&1 && echo -e "${GREEN}✓ custom-it-operations${NC}" || echo -e "${YELLOW}⚠ custom-it-operations fetch failed${NC}"
fi

echo -e "${GREEN}✓ All apps fetched${NC}"

# ================== CREATE SITE ==================
echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

# Clean up old databases
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS \`$(echo ${SITE_NAME} | sed 's/\./_/g')\`;
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
  --admin-password "${ADMIN_PASS}" || die "Failed to create site"

echo -e "${GREEN}✓ Site created${NC}"

# ================== INSTALL APPS ==================
echo -e "${BLUE}Installing apps on site...${NC}"

echo "→ Installing ERPNext..."
bench --site "$SITE_NAME" install-app erpnext || die "Failed to install ERPNext"
echo -e "${GREEN}✓ ERPNext${NC}"

echo "→ Installing HRMS..."
bench --site "$SITE_NAME" install-app hrms || die "Failed to install HRMS"
echo -e "${GREEN}✓ HRMS${NC}"

[ -d "apps/custom-hrms" ] && {
  echo "→ Installing custom-hrms..."
  bench --site "$SITE_NAME" install-app custom-hrms || echo -e "${YELLOW}⚠ custom-hrms installation issues${NC}"
  echo -e "${GREEN}✓ custom-hrms${NC}"
}

[ -d "apps/custom-asset-management" ] && {
  echo "→ Installing custom-asset-management..."
  bench --site "$SITE_NAME" install-app custom-asset-management || echo -e "${YELLOW}⚠ custom-asset-management installation issues${NC}"
  echo -e "${GREEN}✓ custom-asset-management${NC}"
}

[ -d "apps/custom-it-operations" ] && {
  echo "→ Installing custom-it-operations..."
  bench --site "$SITE_NAME" install-app custom-it-operations || echo -e "${YELLOW}⚠ custom-it-operations installation issues${NC}"
  echo -e "${GREEN}✓ custom-it-operations${NC}"
}

# ================== FINALIZE ==================
echo -e "${BLUE}Finalizing setup...${NC}"
bench --site "$SITE_NAME" migrate || true
bench build || true
bench --site "$SITE_NAME" clear-cache || true
bench --site "$SITE_NAME" clear-website-cache || true

echo -e "${BLUE}Installed apps:${NC}"
bench --site "$SITE_NAME" list-apps

# ================== COMPLETION ==================
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  cd ${INSTALL_DIR}/${BENCH_NAME}"
echo "  bench start"
echo ""
echo -e "${BLUE}Access:${NC}"
echo "  URL: http://localhost:8000"
echo "  Site: ${SITE_NAME}"
echo "  Password: ${ADMIN_PASS}"
echo ""
echo -e "${BLUE}Services:${NC}"
echo "  Redis Cache: 127.0.0.1:${REDIS_CACHE_PORT}"
echo "  Redis Queue: 127.0.0.1:${REDIS_QUEUE_PORT}"
echo "  Redis SocketIO: 127.0.0.1:${REDIS_SOCKETIO_PORT}"
echo "  MariaDB: 127.0.0.1:${DB_PORT}"
