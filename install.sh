#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BENCH_DIR="/home/selam/frappe-setup/frappe-bench"
SITE_NAME="mmcy.hrms"
DB_PORT=3307
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"
MYSQL_SOCKET="/run/mysqld/mysqld.sock"

die() {
  echo -e "${RED}ERROR: $1${NC}"
  exit 1
}

success() {
  echo -e "${GREEN}✓ $1${NC}"
}

info() {
  echo -e "${YELLOW}$1${NC}"
}

# ============================================
# PART 1: FRAPPE BASICS INSTALLATION
# ============================================

info "=========================================="
info "PART 1: FRAPPE BASICS INSTALLATION"
info "=========================================="

# Step 1: MariaDB Setup
info "\n[1/6] Preparing MariaDB environment..."
sudo systemctl stop mariadb 2>/dev/null || true
sleep 2

# Kill any processes on ports 3306 and 3307
sudo fuser -k 3306/tcp 2>/dev/null || true
sudo fuser -k 3307/tcp 2>/dev/null || true
sleep 1

# Clean up socket and lock files
sudo rm -f /run/mysqld/mysqld.sock* /var/run/mysqld.pid /var/lib/mysql/mysql.sock* 2>/dev/null || true

# Create directories
sudo mkdir -p /var/log/mysql /var/run/mysqld
sudo chown mysql:mysql /var/log/mysql /var/run/mysqld
sudo chmod 755 /var/log/mysql /var/run/mysqld

# Create log files
sudo touch /var/log/mysql/error.log /var/log/mysql/slow.log
sudo chown mysql:mysql /var/log/mysql/*.log
sudo chmod 644 /var/log/mysql/*.log

# Write MariaDB configuration
info "Writing MariaDB configuration for port ${DB_PORT}..."
sudo tee /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
port = ${DB_PORT}
bind-address = 127.0.0.1
socket = ${MYSQL_SOCKET}
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 16M
thread_stack = 192K
thread_cache_size = 8
myisam_recover_options = BACKUP
query_cache_limit = 1M
query_cache_size = 16M
expire_logs_days = 10
max_binlog_size = 100M
default-storage-engine = InnoDB
innodb_buffer_pool_size = 256M
innodb_log_file_size = 100M
log_error = /var/log/mysql/error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

[mysqldump]
quick
quote-names
max_allowed_packet = 16M

[mysql]
socket = ${MYSQL_SOCKET}

[mysqld_safe]
socket = ${MYSQL_SOCKET}
log_error = /var/log/mysql/error.log
pid-file = /var/run/mysqld/mysqld.pid
EOF

# Reload systemd and start MariaDB
sudo systemctl daemon-reload
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Wait for MariaDB to be ready
info "Waiting for MariaDB to accept connections..."
for i in {1..120}; do
  if mysql --socket="${MYSQL_SOCKET}" -u root -e "SELECT 1" &>/dev/null; then
    success "MariaDB is ready!"
    break
  fi
  if [ $i -eq 120 ]; then
    die "MariaDB did not start within 120 seconds"
  fi
  sleep 1
done

# Verify connection
MYSQL_VERSION=$(mysql --socket="${MYSQL_SOCKET}" -u root -e "SELECT VERSION();" 2>/dev/null | tail -1)
success "MariaDB is running successfully on port ${DB_PORT}"
success "Version: ${MYSQL_VERSION}"

# Step 2: Install system dependencies
info "\n[2/6] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  python3.12 python3.12-dev python3-pip python3-venv \
  nodejs npm yarn \
  git curl wget \
  build-essential libssl-dev libffi-dev \
  redis-server \
  wkhtmltopdf xvfb libfontconfig1 libxrender1 \
  > /dev/null 2>&1
success "System dependencies installed"

# Step 3: Create bench directory and virtual environment
info "\n[3/6] Setting up Frappe bench environment..."
if [ -d "${BENCH_DIR}" ]; then
  info "Bench directory already exists, cleaning up..."
  sudo chmod -R u+w "${BENCH_DIR}" 2>/dev/null || true
  rm -rf "${BENCH_DIR}"
fi

mkdir -p "${BENCH_DIR}"
cd "${BENCH_DIR}"

# Create virtual environment
python3.12 -m venv env
source env/bin/activate

# Upgrade pip
pip install --upgrade pip setuptools wheel > /dev/null 2>&1
success "Virtual environment created"

# Step 4: Initialize Frappe bench
info "\n[4/6] Initializing Frappe bench..."
pip install frappe-bench > /dev/null 2>&1
bench init frappe-bench --frappe-branch version-15 --no-procfile > /dev/null 2>&1
cd frappe-bench
success "Bench frappe-bench initialized"

# Step 5: Clone core apps
info "\n[5/6] Fetching core apps (frappe, erpnext, hrms)..."

clone_with_retry() {
  local repo=$1
  local branch=$2
  local app_name=$3
  local max_attempts=5
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    info "Fetching ${app_name} from branch ${branch}... (Attempt ${attempt}/${max_attempts})"
    
    # Configure git for large repos
    git config --global http.postBuffer 1048576000
    git config --global http.lowSpeedLimit 0
    git config --global http.lowSpeedTime 999999
    
    if git clone --depth 1 --single-branch --branch "${branch}" "${repo}" "apps/${app_name}" 2>&1; then
      success "${app_name} fetched"
      return 0
    fi
    
    # Clean up partial clone
    rm -rf "apps/${app_name}"
    
    if [ $attempt -lt $max_attempts ]; then
      local wait_time=$((10 * attempt))
      info "Retrying in ${wait_time} seconds..."
      sleep $wait_time
    fi
    
    attempt=$((attempt + 1))
  done
  
  die "Failed to fetch ${app_name} after ${max_attempts} attempts"
}

# Clone apps in order
clone_with_retry "https://github.com/frappe/frappe.git" "version-15" "frappe"
clone_with_retry "https://github.com/frappe/erpnext.git" "version-15" "erpnext"
clone_with_retry "https://github.com/frappe/hrms.git" "version-15" "hrms"

success "All core apps fetched"

# Step 6: Create site
info "\n[6/6] Creating site '${SITE_NAME}'..."

# Clean up any existing database
mysql --socket="${MYSQL_SOCKET}" -u root -e "DROP DATABASE IF EXISTS \`${SITE_NAME}\`;" 2>/dev/null || true
mysql --socket="${MYSQL_SOCKET}" -u root -e "DROP USER IF EXISTS '${SITE_NAME}'@'localhost';" 2>/dev/null || true

# Create new site
bench new-site "${SITE_NAME}" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" \
  --no-mariadb-socket || die "Failed to create site '${SITE_NAME}'"

success "Site '${SITE_NAME}' created successfully"

# Install core apps on site
info "Installing core apps on site..."
bench install-app frappe > /dev/null 2>&1
bench install-app erpnext > /dev/null 2>&1
bench install-app hrms > /dev/null 2>&1

success "Core apps installed on site"

# Build and clear cache
info "Building assets and clearing cache..."
bench build > /dev/null 2>&1
bench clear-cache > /dev/null 2>&1

# ============================================
# PART 1 COMPLETE
# ============================================

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ PART 1 INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Installed apps:"
bench list-apps
echo ""
echo "Next steps:"
echo "1. Start the server: bench start"
echo "2. Access at: http://localhost:8000/app/home"
echo "3. Login credentials:"
echo "   Site: ${SITE_NAME}"
echo "   Admin Password: ${ADMIN_PASS}"
echo ""
echo "After verifying Part 1 works, run: bash install-part2-custom-apps.sh"
echo ""
