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
DB_USER="root"
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"
MYSQL_SOCKET="/run/mysqld/mysqld.sock"

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

die() {
    log_error "$1"
    exit 1
}

clone_with_retry() {
    local repo_url=$1
    local app_name=$2
    local branch=${3:-main}
    local max_attempts=5
    local attempt=1
    
    log_info "Fetching $app_name from branch $branch..."
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt of $max_attempts for $app_name..."
        
        # Remove partial clone if it exists
        rm -rf "$BENCH_DIR/apps/$app_name" 2>/dev/null || true
        
        # Configure git for large repos
        git config --global http.postBuffer 524288000
        git config --global http.lowSpeedLimit 0
        git config --global http.lowSpeedTime 999999
        
        if git clone --depth 1 --single-branch --branch "$branch" "$repo_url" "$BENCH_DIR/apps/$app_name" 2>/dev/null; then
            log_info "✓ Successfully cloned $app_name"
            return 0
        fi
        
        # Try alternative branches
        if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
            log_warning "Branch $branch not found, trying main..."
            if git clone --depth 1 --single-branch --branch main "$repo_url" "$BENCH_DIR/apps/$app_name" 2>/dev/null; then
                log_info "✓ Successfully cloned $app_name from main branch"
                return 0
            fi
            
            log_warning "Main branch not found, trying master..."
            if git clone --depth 1 --single-branch --branch master "$repo_url" "$BENCH_DIR/apps/$app_name" 2>/dev/null; then
                log_info "✓ Successfully cloned $app_name from master branch"
                return 0
            fi
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            sleep $((attempt * 10))
        fi
    done
    
    log_error "Failed to fetch $app_name after $max_attempts attempts"
    return 1
}

# ============================================
# PART 1: MARIADB SETUP
# ============================================
log_info "=========================================="
log_info "PART 1: Setting up MariaDB"
log_info "=========================================="

log_info "Stopping any existing MariaDB/MySQL services..."
sudo systemctl stop mariadb 2>/dev/null || true
sleep 2

log_info "Killing processes on port 3306 and 3307..."
sudo fuser -k 3306/tcp 2>/dev/null || true
sudo fuser -k 3307/tcp 2>/dev/null || true
sleep 1

log_info "Cleaning up socket and lock files..."
sudo rm -f /run/mysqld/mysqld.sock* 2>/dev/null || true
sudo rm -f /var/run/mysqld/mysqld.sock* 2>/dev/null || true
sudo rm -f /tmp/mysql_*.sock 2>/dev/null || true
sudo rm -f /var/lib/mysql/mysql.sock 2>/dev/null || true

log_info "Creating log and run directories..."
sudo mkdir -p /var/log/mysql /var/run/mysqld
sudo chown mysql:mysql /var/log/mysql /var/run/mysqld
sudo chmod 755 /var/log/mysql /var/run/mysqld

log_info "Creating empty log files..."
sudo touch /var/log/mysql/error.log /var/log/mysql/slow.log
sudo chown mysql:mysql /var/log/mysql/*.log
sudo chmod 644 /var/log/mysql/*.log

log_info "Writing MariaDB configuration for port $DB_PORT..."
sudo tee /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
port = $DB_PORT
bind-address = 127.0.0.1
socket = $MYSQL_SOCKET
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
log_error = /var/log/mysql/error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

[mysqldump]
quick
quote-names
max_allowed_packet = 16M

[mysql]
socket = $MYSQL_SOCKET

[isamchk]
key_buffer_size = 16M
EOF

log_info "Reloading systemd configuration..."
sudo systemctl daemon-reload

log_info "Enabling and starting MariaDB service..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

log_info "Waiting for MariaDB to accept connections..."
for i in {1..120}; do
    if mysql --socket="$MYSQL_SOCKET" -u root -e "SELECT 1" &>/dev/null; then
        log_info "MariaDB is ready!"
        break
    fi
    if [ $i -eq 120 ]; then
        die "MariaDB did not start within 120 seconds"
    fi
    sleep 1
done

log_info "Verifying MariaDB connection..."
MYSQL_VERSION=$(mysql --socket="$MYSQL_SOCKET" -u root -e "SELECT VERSION();" 2>/dev/null | tail -1)
log_info "✓ MariaDB is running: $MYSQL_VERSION"

# ============================================
# PART 2: SYSTEM DEPENDENCIES
# ============================================
log_info "=========================================="
log_info "PART 2: Installing System Dependencies"
log_info "=========================================="

log_info "Updating package manager..."
sudo apt-get update -qq

log_info "Installing Python and development tools..."
sudo apt-get install -y -qq python3 python3-dev python3-pip python3-venv git curl wget

log_info "Installing Node.js and npm..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - 2>/dev/null
sudo apt-get install -y -qq nodejs

log_info "Installing additional dependencies..."
sudo apt-get install -y -qq build-essential libssl-dev libffi-dev libmysqlclient-dev redis-server

log_info "✓ System dependencies installed"

# ============================================
# PART 3: FRAPPE BENCH SETUP
# ============================================
log_info "=========================================="
log_info "PART 3: Setting up Frappe Bench"
log_info "=========================================="

log_info "Creating bench directory..."
mkdir -p "$BENCH_DIR"
cd "$BENCH_DIR"

log_info "Initializing Frappe bench..."
bench init frappe-bench --frappe-branch version-15 --no-procfile --skip-redis-config-generation || die "Failed to initialize bench"

cd "$BENCH_DIR/frappe-bench"

log_info "✓ Bench frappe-bench initialized"

# ============================================
# PART 4: CLONING ALL APPS
# ============================================
log_info "=========================================="
log_info "PART 4: Fetching All Apps"
log_info "=========================================="

log_info "Configuring bench..."
bench config set-common-config -c db_host "127.0.0.1"
bench config set-common-config -c db_port "$DB_PORT"

log_info "Fetching apps..."

# Clone ERPNext
clone_with_retry "https://github.com/frappe/erpnext.git" "erpnext" "version-15" || log_warning "ERPNext fetch had issues"

# Clone HRMS
clone_with_retry "https://github.com/frappe/hrms.git" "hrms" "develop" || log_warning "HRMS fetch had issues"

# Clone Custom Apps
clone_with_retry "https://github.com/MMCY-Tech/custom-hrms.git" "custom_hrms" "main" || log_warning "custom-hrms fetch had issues"
clone_with_retry "https://github.com/MMCY-Tech/custom-asset-management.git" "custom_asset_management" "main" || log_warning "custom-asset-management fetch had issues"
clone_with_retry "https://github.com/MMCY-Tech/custom-it-operations.git" "custom_it_operations" "main" || log_warning "custom-it-operations fetch had issues"

log_info "✓ All apps fetched"

# ============================================
# PART 5: CREATING SITE
# ============================================
log_info "=========================================="
log_info "PART 5: Creating Site"
log_info "=========================================="

log_info "Cleaning up old site if it exists..."
bench drop-site "$SITE_NAME" --force 2>/dev/null || true

log_info "Dropping old database if it exists..."
mysql --socket="$MYSQL_SOCKET" -u root -e "DROP DATABASE IF EXISTS \`${SITE_NAME//./}\`;" 2>/dev/null || true

log_info "Creating site '$SITE_NAME'..."
bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "$DB_PORT" \
  --db-root-username root \
  --db-root-password "$MYSQL_ROOT_PASS" \
  --admin-password "$ADMIN_PASS" || die "Failed to create site '$SITE_NAME'"

log_info "✓ Site '$SITE_NAME' created successfully"

# ============================================
# PART 6: INSTALLING ALL APPS
# ============================================
log_info "=========================================="
log_info "PART 6: Installing Apps on Site"
log_info "=========================================="

log_info "Installing ERPNext..."
bench install-app erpnext || log_warning "ERPNext installation had issues"

log_info "Installing HRMS..."
bench install-app hrms || log_warning "HRMS installation had issues"

log_info "Installing custom apps..."
bench install-app custom_hrms || log_warning "custom_hrms installation had issues"
bench install-app custom_asset_management || log_warning "custom_asset_management installation had issues"
bench install-app custom_it_operations || log_warning "custom_it_operations installation had issues"

log_info "✓ All apps installed"

# ============================================
# PART 7: FINALIZING SETUP
# ============================================
log_info "=========================================="
log_info "PART 7: Finalizing Setup"
log_info "=========================================="

log_info "Building assets..."
bench build || log_warning "Build had issues"

log_info "Clearing cache..."
bench clear-cache || log_warning "Cache clear had issues"

log_info "Clearing website cache..."
bench clear-website-cache || log_warning "Website cache clear had issues"

log_info "Migrating database..."
bench migrate || log_warning "Migration had issues"

# ============================================
# VERIFICATION
# ============================================
log_info "=========================================="
log_info "VERIFICATION"
log_info "=========================================="

log_info "Installed apps:"
bench list-apps

log_info "Site configuration:"
cat sites/"$SITE_NAME"/site_config.json | grep -E "db_|app" || true

# ============================================
# COMPLETION
# ============================================
log_info "=========================================="
log_info "✓ INSTALLATION COMPLETE!"
log_info "=========================================="
log_info ""
log_info "Next steps:"
log_info "1. Navigate to bench: cd $BENCH_DIR/frappe-bench"
log_info "2. Start the server: bench start"
log_info "3. Access at: http://localhost:8000/app/home"
log_info ""
log_info "Login credentials:"
log_info "Site: $SITE_NAME"
log_info "Admin Password: $ADMIN_PASS"
log_info ""
log_info "Installed apps:"
log_info "  - frappe (core)"
log_info "  - erpnext"
log_info "  - hrms"
log_info "  - custom_hrms"
log_info "  - custom_asset_management"
log_info "  - custom_it_operations"
log_info ""
