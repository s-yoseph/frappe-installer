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
SITE_NAME="hrms.mmcy"
DB_PORT=3307
REDIS_CACHE_PORT=11000
REDIS_QUEUE_PORT=12000
REDIS_SOCKETIO_PORT=13000
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"

export PYTHONBREAKPOINT=0
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PATH="$HOME/.local/bin:$PATH"

export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_CONNECTTIMEOUT=120
export GIT_HTTP_LOWSPEEDLIMIT=1000
export GIT_HTTP_LOWSPEEDTIME=120
export GIT_CURL_VERBOSE=0

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

retry_get_app() {
  local app_name=$1
  local branch=$2
  local url=$3
  local max_attempts=3
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo -e "${BLUE}[Attempt $attempt/$max_attempts] Fetching $app_name from branch $branch...${NC}"
    
    if bench get-app --branch "$branch" "$app_name" "$url" 2>&1; then
      echo -e "${GREEN}✓ $app_name fetched successfully${NC}"
      return 0
    fi
    
    if [ $attempt -lt $max_attempts ]; then
      echo -e "${YELLOW}⚠ $app_name fetch failed, retrying in 15 seconds...${NC}"
      sleep 15
    fi
    
    attempt=$((attempt + 1))
  done
  
  echo -e "${YELLOW}⚠ Failed to fetch $app_name after $max_attempts attempts${NC}"
  return 1
}

echo -e "${BLUE}Installing Frappe (Fresh Start)...${NC}"

# Install dependencies
sudo apt update -y
sudo apt install -y python3-dev python3.12-venv python3-pip redis-server mariadb-server mariadb-client curl git build-essential nodejs jq
sudo npm install -g yarn || true

echo -e "${BLUE}Aggressively clearing ports...${NC}"
sudo pkill -9 -f redis-server 2>/dev/null || true
sudo lsof -i :${REDIS_CACHE_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
sudo lsof -i :${REDIS_QUEUE_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
sudo lsof -i :${REDIS_SOCKETIO_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
sleep 3

REDIS_CONFIG_DIR="${HOME}/.redis"
mkdir -p "$REDIS_CONFIG_DIR"

echo -e "${BLUE}Setting up Redis instances with standard Frappe ports...${NC}"
sudo systemctl stop redis-server || true
sleep 2

# Stop any existing Redis instances on our ports
sudo fuser -k ${REDIS_CACHE_PORT}/tcp 2>/dev/null || true
sudo fuser -k ${REDIS_QUEUE_PORT}/tcp 2>/dev/null || true
sudo fuser -k ${REDIS_SOCKETIO_PORT}/tcp 2>/dev/null || true
sleep 2

echo -e "${BLUE}Configuring Redis cache on port ${REDIS_CACHE_PORT}...${NC}"
cat > "$REDIS_CONFIG_DIR/redis-cache.conf" <<EOF
port ${REDIS_CACHE_PORT}
bind 127.0.0.1
timeout 0
tcp-keepalive 300
daemonize no
supervised no
pidfile ${REDIS_CONFIG_DIR}/redis-cache.pid
loglevel notice
logfile ""
databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump-cache.rdb
dir ${REDIS_CONFIG_DIR}
appendonly no
EOF

echo -e "${BLUE}Configuring Redis queue on port ${REDIS_QUEUE_PORT}...${NC}"
cat > "$REDIS_CONFIG_DIR/redis-queue.conf" <<EOF
port ${REDIS_QUEUE_PORT}
bind 127.0.0.1
timeout 0
tcp-keepalive 300
daemonize no
supervised no
pidfile ${REDIS_CONFIG_DIR}/redis-queue.pid
loglevel notice
logfile ""
databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump-queue.rdb
dir ${REDIS_CONFIG_DIR}
appendonly no
EOF

echo -e "${BLUE}Configuring Redis socketio on port ${REDIS_SOCKETIO_PORT}...${NC}"
cat > "$REDIS_CONFIG_DIR/redis-socketio.conf" <<EOF
port ${REDIS_SOCKETIO_PORT}
bind 127.0.0.1
timeout 0
tcp-keepalive 300
daemonize no
supervised no
pidfile ${REDIS_CONFIG_DIR}/redis-socketio.pid
loglevel notice
logfile ""
databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump-socketio.rdb
dir ${REDIS_CONFIG_DIR}
appendonly no
EOF

echo -e "${BLUE}Starting Redis instances...${NC}"
redis-server "$REDIS_CONFIG_DIR/redis-cache.conf" &
REDIS_CACHE_PID=$!
sleep 2

redis-server "$REDIS_CONFIG_DIR/redis-queue.conf" &
REDIS_QUEUE_PID=$!
sleep 2

redis-server "$REDIS_CONFIG_DIR/redis-socketio.conf" &
REDIS_SOCKETIO_PID=$!
sleep 2

# Verify all Redis instances are running
echo -e "${BLUE}Verifying Redis instances...${NC}"
for i in {1..30}; do
  CACHE_OK=false
  QUEUE_OK=false
  SOCKETIO_OK=false
  
  redis-cli -p ${REDIS_CACHE_PORT} ping >/dev/null 2>&1 && CACHE_OK=true || true
  redis-cli -p ${REDIS_QUEUE_PORT} ping >/dev/null 2>&1 && QUEUE_OK=true || true
  redis-cli -p ${REDIS_SOCKETIO_PORT} ping >/dev/null 2>&1 && SOCKETIO_OK=true || true
  
  if [ "$CACHE_OK" = true ] && [ "$QUEUE_OK" = true ] && [ "$SOCKETIO_OK" = true ]; then
    echo -e "${GREEN}✓ All Redis instances are ready${NC}"
    break
  fi
  
  if [ $i -eq 30 ]; then
    die "Redis instances failed to start properly"
  fi
  
  echo "Waiting for Redis instances... attempt $i/30"
  sleep 1
done

echo -e "${GREEN}✓ Redis ready on standard Frappe ports${NC}"

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
bench config set-common-config -c redis_cache "'redis://127.0.0.1:${REDIS_CACHE_PORT}'" || true
bench config set-common-config -c redis_queue "'redis://127.0.0.1:${REDIS_QUEUE_PORT}'" || true
bench config set-common-config -c redis_socketio "'redis://127.0.0.1:${REDIS_SOCKETIO_PORT}'" || true

echo -e "${BLUE}Fetching apps...${NC}"

echo "Fetching ERPNext from branch ${ERPNEXT_BRANCH}..."
retry_get_app "erpnext" "$ERPNEXT_BRANCH" "https://github.com/frappe/erpnext" || die "Failed to get ERPNext after retries"
echo -e "${GREEN}✓ ERPNext fetched${NC}"

echo "Fetching HRMS from branch ${HRMS_BRANCH}..."
retry_get_app "hrms" "$HRMS_BRANCH" "https://github.com/frappe/hrms" || die "Failed to get HRMS after retries"
echo -e "${GREEN}✓ HRMS fetched${NC}"

if [ -z "${GITHUB_TOKEN}" ]; then
  echo -e "${YELLOW}⚠ No GitHub token provided - custom apps will be skipped${NC}"
  echo -e "${YELLOW}To include custom apps, run: bash install-frappe-complete.sh -t YOUR_GITHUB_TOKEN${NC}"
else
  echo -e "${GREEN}✓ GitHub token received${NC}"

  retry_get_app "custom-hrms" "$CUSTOM_BRANCH" "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-hrms.git" || echo -e "${YELLOW}⚠ custom-hrms not available${NC}"

  retry_get_app "custom-asset-management" "$CUSTOM_BRANCH" "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-asset-management.git" || echo -e "${YELLOW}⚠ custom-asset-management not available${NC}"

  retry_get_app "custom-it-operations" "$CUSTOM_BRANCH" "https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-it-operations.git" || echo -e "${YELLOW}⚠ custom-it-operations not available${NC}"
fi

echo -e "${GREEN}✓ All apps fetched${NC}"

echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

echo "Cleaning up any leftover databases..."
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS \`$(echo ${SITE_NAME} | sed 's/\./_/g')\`;
DROP DATABASE IF EXISTS \`_9dd2166bc4fc2357\`;
DROP DATABASE IF EXISTS \`_afd6259a990fe66d\`;
FLUSH PRIVILEGES;
SQL

echo "Removing all orphaned databases (starting with underscore)..."
TEMP_DROP_FILE=$(mktemp)
trap "rm -f '$TEMP_DROP_FILE'" EXIT

mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" 2>/dev/null <<SQL > "$TEMP_DROP_FILE" || true
SELECT CONCAT('DROP DATABASE IF EXISTS \`', schema_name, '\`;') 
FROM information_schema.schemata 
WHERE schema_name LIKE '\_%' 
AND schema_name NOT IN ('_mysql', '_performance_schema', '_information_schema');
SQL

if [ -s "$TEMP_DROP_FILE" ]; then
  mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" < "$TEMP_DROP_FILE" 2>/dev/null || true
fi

rm -rf "sites/${SITE_NAME}" 2>/dev/null || true

sleep 3

bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" || die "Failed to create site '${SITE_NAME}'"

echo -e "${GREEN}✓ Site created${NC}"

echo -e "${BLUE}Verifying Redis instances are accessible...${NC}"
if ! redis-cli -p ${REDIS_CACHE_PORT} ping >/dev/null 2>&1; then
  die "Redis cache on port ${REDIS_CACHE_PORT} is not accessible"
fi
if ! redis-cli -p ${REDIS_QUEUE_PORT} ping >/dev/null 2>&1; then
  die "Redis queue on port ${REDIS_QUEUE_PORT} is not accessible"
fi
if ! redis-cli -p ${REDIS_SOCKETIO_PORT} ping >/dev/null 2>&1; then
  die "Redis socketio on port ${REDIS_SOCKETIO_PORT} is not accessible"
fi

echo -e "${GREEN}✓ All Redis instances verified${NC}"

echo -e "${BLUE}Installing apps on site...${NC}"

echo "Installing ERPNext..."
bench --site "$SITE_NAME" install-app erpnext || die "Failed to install ERPNext"
echo -e "${GREEN}✓ ERPNext installed${NC}"

echo "Installing HRMS..."
bench --site "$SITE_NAME" install-app hrms || die "Failed to install HRMS"
echo -e "${GREEN}✓ HRMS installed${NC}"

if [ -d "apps/custom-hrms" ]; then
  echo "Installing custom-hrms..."
  bench --site "$SITE_NAME" install-app custom_hrms || echo -e "${YELLOW}⚠ custom_hrms installation had issues${NC}   custom_hrms installation may require migration later${NC}"
  echo -e "${GREEN}✓ custom_hrms installed${NC}"
fi

if [ -d "apps/custom-asset-management" ]; then
  echo "Installing custom-asset-management..."
  bench --site "$SITE_NAME" install-app custom_asset_management || echo -e "${YELLOW}⚠ custom_asset_management installation had issues${NC}  mmcy_asset_management installation may require migration later${NC}"
  echo -e "${GREEN}✓ custom_asset_management installed${NC}"
fi

if [ -d "apps/custom-it-operations" ]; then
  echo "Installing custom-it-operations..."
  bench --site "$SITE_NAME" install-app custom_it_operations || echo -e "${YELLOW}⚠ custom_it_operations installation had issues${NC}  mmcy_it_operations installation may require migration later${NC}" 
  echo -e "${GREEN}✓ custom_it_operations installed${NC}"
fi

echo -e "${BLUE}Running migrate...${NC}"
bench --site "$SITE_NAME" migrate || true

echo -e "${BLUE}Building assets and clearing cache...${NC}"
bench build || true
bench --site "$SITE_NAME" clear-cache || true
bench --site "$SITE_NAME" clear-website-cache || true

echo -e "${BLUE}Setting up Procfile with correct Redis configuration...${NC}"
cat > Procfile <<EOF
redis_cache: redis-server ${REDIS_CONFIG_DIR}/redis-cache.conf
redis_queue: redis-server ${REDIS_CONFIG_DIR}/redis-queue.conf
redis_socketio: redis-server ${REDIS_CONFIG_DIR}/redis-socketio.conf
web: bench serve --port 8000
socketio: node apps/frappe/socketio.js
schedule: bench schedule
worker: bench worker
watch: bench watch
EOF
echo -e "${GREEN}✓ Procfile configured${NC}"

echo -e "${BLUE}Restarting bench services...${NC}"
bench restart || echo -e "${YELLOW}⚠ Bench will restart on next 'bench start'${NC}"

echo -e "${BLUE}Fixing company abbreviation for MMCYTech...${NC}"
bench --site "$SITE_NAME" execute "
import frappe
frappe.connect()
try:
    frappe.db.set_value('Company', 'MMCYTech', 'abbr', 'MT', update_modified=False)
    frappe.db.commit()
    print('✓ Company abbreviation set to MT')
except Exception as e:
    print(f'Company abbreviation will be set on first login: {str(e)}')
" || echo -e "${YELLOW}⚠ Company abbreviation will need manual setup${NC}"

echo -e "${BLUE}Verifying installed apps...${NC}"
bench --site "$SITE_NAME" list-apps

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
echo -e "${BLUE}Installed apps:${NC}"
echo "  - frappe (core framework)"
echo "  - erpnext (ERP system)"
echo "  - hrms (HR module)"
echo "  - custom-hrms (your custom HRMS)"
echo "  - custom-asset-management (your custom asset management)"
echo "  - custom-it-operations (your custom IT operations)"
echo ""
echo -e "${BLUE}Redis configuration:${NC}"
echo "  - Cache: port ${REDIS_CACHE_PORT}"
echo "  - Queue: port ${REDIS_QUEUE_PORT}"
echo "  - SocketIO: port ${REDIS_SOCKETIO_PORT}"
echo ""
echo -e "${BLUE}All custom MMCY apps have been installed on site: ${SITE_NAME}${NC}"
echo ""
