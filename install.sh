#!/usr/bin/env bash
set -e

# ==========================================
# CONFIGURATION
# ==========================================
GITHUB_TOKEN=""
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"

BENCH_NAME="frappe-bench"
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="hrms.mmcy"

# Ports
DB_PORT=3307
REDIS_CACHE_PORT=11000
REDIS_QUEUE_PORT=12000
REDIS_SOCKETIO_PORT=13000
WEB_PORT=8000

# Database Credentials
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"

# ==========================================
# ARGUMENT PARSING
# ==========================================
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

# ==========================================
# OS DETECTION & HELPER FUNCTIONS
# ==========================================
OS_TYPE=$(uname -s)
case "$OS_TYPE" in
    Linux*)     OS_NAME="Linux" ;;
    Darwin*)    OS_NAME="Mac" ;;
    *)          echo "Unknown OS: $OS_TYPE"; exit 1 ;;
esac

echo "Detected OS: $OS_NAME"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ==========================================
# SYSTEM DEPENDENCIES
# ==========================================
install_dependencies() {
    log "Installing System Dependencies..."

    if [ "$OS_NAME" == "Linux" ]; then
        # Ubuntu/Debian/WSL
        sudo apt-get update -y
        sudo apt-get install -y git python3-dev python3-pip python3-venv redis-server software-properties-common mariadb-server mariadb-client xvfb libfontconfig wkhtmltopdf curl build-essential nodejs npm

        # Install Yarn
        if ! command_exists yarn; then
            sudo npm install -g yarn
        fi

    elif [ "$OS_NAME" == "Mac" ]; then
        # macOS
        if ! command_exists brew; then
            error "Homebrew is not installed. Please install it first: https://brew.sh/"
        fi
        
        log "Updating Homebrew..."
        brew update

        brew install python@3.11 git redis mariadb node wkhtmltopdf
        brew install yarn
    fi
    success "Dependencies installed."
}

# ==========================================
# MARIADB CONFIGURATION
# ==========================================
configure_mariadb() {
    log "Configuring MariaDB..."

    CONFIG_CONTENT="[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
bind-address = 127.0.0.1
innodb_buffer_pool_size = 256M
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
innodb_log_buffer_size = 8M
innodb_log_file_size = 100M
max_allowed_packet = 64M
port = ${DB_PORT}
"

    if [ "$OS_NAME" == "Linux" ]; then
        echo "$CONFIG_CONTENT" | sudo tee /etc/mysql/mariadb.conf.d/99-frappe.cnf > /dev/null
        sudo service mariadb restart
    elif [ "$OS_NAME" == "Mac" ]; then
        # Brew MariaDB config location usually in /opt/homebrew/etc/my.cnf.d/
        CONFIG_DIR="$(brew --prefix)/etc/my.cnf.d"
        mkdir -p "$CONFIG_DIR"
        echo "$CONFIG_CONTENT" > "$CONFIG_DIR/99-frappe.cnf"
        brew services restart mariadb
    fi
    
    # Wait for DB to start
    sleep 5

    log "Securing MariaDB..."
    # Attempt to set root password. Use sudo for Linux socket auth, or standard login for Mac.
    if [ "$OS_NAME" == "Linux" ]; then
        sudo mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;" || warn "Could not set root password (maybe already set?)"
    else
        mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;" || warn "Could not set root password (maybe already set?)"
    fi
    success "MariaDB Configured."
}

# ==========================================
# REDIS CONFIGURATION (USER LEVEL)
# ==========================================
configure_redis() {
    log "Configuring Local Redis Instances..."
    
    REDIS_DIR="$HOME/.redis_frappe"
    mkdir -p "$REDIS_DIR"

    # Stop existing if any
    pkill -f "redis-server.*$REDIS_CACHE_PORT" || true
    pkill -f "redis-server.*$REDIS_QUEUE_PORT" || true
    pkill -f "redis-server.*$REDIS_SOCKETIO_PORT" || true

    # Helper to generate config
    create_redis_conf() {
        local port=$1
        local name=$2
        cat > "$REDIS_DIR/$name.conf" <<EOF
port $port
bind 127.0.0.1
daemonize yes
pidfile $REDIS_DIR/$name.pid
dir $REDIS_DIR
dbfilename $name.rdb
save ""
appendonly no
EOF
        redis-server "$REDIS_DIR/$name.conf"
    }

    create_redis_conf $REDIS_CACHE_PORT "redis-cache"
    create_redis_conf $REDIS_QUEUE_PORT "redis-queue"
    create_redis_conf $REDIS_SOCKETIO_PORT "redis-socketio"

    success "Redis instances started on ports $REDIS_CACHE_PORT, $REDIS_QUEUE_PORT, $REDIS_SOCKETIO_PORT."
}

# ==========================================
# BENCH SETUP
# ==========================================
setup_bench() {
    # Install Bench CLI
    if ! command_exists bench; then
        log "Installing Frappe Bench CLI..."
        # Use pip3 with break-system-packages if on newer Linux/Mac, or pipx
        python3 -m pip install --user frappe-bench --break-system-packages 2>/dev/null || python3 -m pip install --user frappe-bench
    fi

    # Add local bin to PATH for this session
    export PATH=$PATH:$HOME/.local/bin

    # Clean install dir
    if [ -d "$INSTALL_DIR" ]; then
        warn "Directory $INSTALL_DIR exists. Backing up..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}_backup_$(date +%s)"
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    log "Initializing Bench (Frappe $FRAPPE_BRANCH)..."
    
    # Init command
    bench init "$BENCH_NAME" \
        --frappe-branch "$FRAPPE_BRANCH" \
        --python python3 \
        --no-procfile \
        --no-backups \
        --verbose

    cd "$BENCH_NAME"

    # Config Bench for Custom Ports
    bench config set-common-config -c db_host "127.0.0.1"
    bench config set-common-config -c db_port "$DB_PORT"
    bench config set-common-config -c redis_cache "redis://127.0.0.1:$REDIS_CACHE_PORT"
    bench config set-common-config -c redis_queue "redis://127.0.0.1:$REDIS_QUEUE_PORT"
    bench config set-common-config -c redis_socketio "redis://127.0.0.1:$REDIS_SOCKETIO_PORT"
    bench config set-common-config -c web_server_port "$WEB_PORT"
}

# ==========================================
# APP INSTALLATION
# ==========================================
install_apps() {
    log "Fetching Apps..."

    # 1. ERPNext
    if [ ! -d "apps/erpnext" ]; then
        bench get-app erpnext --branch "$ERPNEXT_BRANCH" --resolve-deps
    fi

    # 2. HRMS
    if [ ! -d "apps/hrms" ]; then
        bench get-app hrms --branch "$HRMS_BRANCH" --resolve-deps
    fi

    # 3. Custom Apps
    if [ -z "$GITHUB_TOKEN" ]; then
        warn "No GitHub Token provided. Skipping private custom apps."
    else
        log "Fetching Custom Apps using Token..."
        
        # Function to safely get app
        get_custom_app() {
            local url=$1
            local name=$2 # Optional: expected folder name
            
            log "Getting $url..."
            # Note: bench get-app handles auth if url includes token
            if ! bench get-app "$url" --branch "$CUSTOM_BRANCH" --resolve-deps; then
                warn "Failed to fetch $url. Check permissions or branch name."
            else
                success "Fetched $url"
            fi
        }

        # MMCY Apps
        # Note: We construct the URL with the token
        get_custom_app "https://${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-hrms.git"
        get_custom_app "https://${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-asset-management.git"
        get_custom_app "https://${GITHUB_TOKEN}@github.com/MMCY-Tech/custom-it-operations.git"
    fi
}

# ==========================================
# SITE CREATION
# ==========================================
create_site() {
    log "Creating Site: $SITE_NAME"

    # Force re-install if exists
    rm -rf "sites/$SITE_NAME"

    bench new-site "$SITE_NAME" \
        --db-root-password "$MYSQL_ROOT_PASS" \
        --admin-password "$ADMIN_PASS" \
        --db-host "127.0.0.1" \
        --db-port "$DB_PORT" \
        --install-app erpnext \
        --force

    log "Installing HRMS..."
    bench --site "$SITE_NAME" install-app hrms

    # Install Custom Apps if they exist in apps/ folder
    log "Attempting to install Custom Apps..."
    
    # We loop through directory names in apps/ to find matches
    # This fixes issues where repo name != app name
    
    install_if_exists() {
        local folder_name=$1
        local app_python_name=$2 # Usually same as folder, but sometimes underscores vs dashes
        
        if [ -d "apps/$folder_name" ]; then
            log "Installing $app_python_name..."
            bench --site "$SITE_NAME" install-app "$app_python_name" || warn "Failed to install $app_python_name (might require migration)"
        fi
    }

    # Adjust these names based on the actual folder names created inside `frappe-bench/apps/`
    install_if_exists "custom-hrms" "mmcy_hrms"
    install_if_exists "custom-asset-management" "mmcy_asset_management"
    install_if_exists "custom-it-operations" "mmcy_it_operations"
    
    # Force Migrate to ensure DB schema is correct
    log "Running Migrations..."
    bench --site "$SITE_NAME" migrate
}

# ==========================================
# MAIN EXECUTION
# ==========================================

# 1. Setup Environment
install_dependencies

# 2. Setup Services
configure_mariadb
configure_redis

# 3. Setup Bench
setup_bench

# 4. Get Apps
install_apps

# 5. Create Site & Install Apps
create_site

# 6. Generate Procfile for development
log "Generating Procfile..."
cat > Procfile <<EOF
web: bench serve --port $WEB_PORT
socketio: node apps/frappe/socketio.js
watch: bench watch
schedule: bench schedule
worker_short: bench worker --queue short
worker_long: bench worker --queue long
worker_default: bench worker --queue default
EOF

success "=================================================="
success "INSTALLATION COMPLETE"
success "=================================================="
echo "Run the following to start:"
echo "  cd $INSTALL_DIR/$BENCH_NAME"
echo "  bench start"
echo ""
echo "Access your site at: http://localhost:$WEB_PORT"
echo "Login: Administrator / $ADMIN_PASS"
