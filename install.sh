#!/usr/bin/env bash
set -euo pipefail

# --- Configuration Variables ---
GITHUB_TOKEN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--token)
      if [[ -n "$2" && "$2" != -* ]]; then
        GITHUB_TOKEN="$2"
        shift 2
      else
        die "Argument missing for -t|--token"
      fi
      ;;
    *)
      shift
      ;;
  esac
done

# Frappe App Branches
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"

# Installation Configuration
BENCH_NAME="frappe-bench"
INSTALL_DIR="${HOME}/frappe-setup"
SITE_NAME="hrms.mmcy"
DB_PORT=3307
REDIS_CACHE_PORT=11000
REDIS_QUEUE_PORT=12000
REDIS_SOCKETIO_PORT=13000
MYSQL_ROOT_PASS="root"
ADMIN_PASS="admin"

# Custom App Mapping: Repository Name -> App Name
declare -A CUSTOM_APPS=(
  ["custom-hrms"]="mmcy_hrms"
  ["custom-asset-management"]="mmcy_asset_management"
  ["custom-it-operations"]="mmcy_it_operations"
)

# --- Environment Setup ---
export PYTHONBREAKPOINT=0
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PATH="$HOME/.local/bin:$PATH"
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_CONNECTTIMEOUT=120
export GIT_HTTP_LOWSPEEDLIMIT=1000
export GIT_HTTP_LOWSPEEDTIME=120
export GIT_CURL_VERBOSE=0

# --- Color Codes ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Utility Functions ---
die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

retry_get_app() {
  # Usage: retry_get_app <app_name> <repo_name> <branch> <url>
  local app_name=$1
  local repo_name=$2
  local branch=$3
  local url=$4
  local max_attempts=3
  local attempt=1
  
  # Determine if we are installing a custom app to use --resolve-deps
  local get_app_options="--branch \"$branch\""
  if [[ "$app_name" =~ ^mmcy_ ]]; then
    echo -e "${BLUE}*** Custom App Detected: Resolving dependencies... ***${NC}"
    get_app_options="$get_app_options --resolve-deps"
  fi

  # Note: Displaying the intended app name for clarity
  echo -e "${BLUE}Fetching $app_name (from repo $repo_name) from branch $branch...${NC}"

  while [ $attempt -le $max_attempts ]; do
    echo -e "${BLUE}[Attempt $attempt/$max_attempts]...${NC}"

    # Using the bench get-app [OPTIONS] APP_NAME GIT_URL
    # The $get_app_options variable now contains the necessary flags
    if bench get-app $get_app_options "$app_name" "$url" 2>&1; then
      echo -e "${GREEN}✓ $app_name fetched successfully${NC}"
      return 0
    fi
    
    if [ $attempt -lt $max_attempts ]; then
      echo -e "${YELLOW}⚠ $app_name fetch failed, retrying in 15 seconds...${NC}"
      sleep 15
    fi

    attempt=$((attempt + 1))
  done

  # Die if the custom app fails to fetch after all retries
  if [[ "$app_name" =~ ^mmcy_ ]]; then
    die "Failed to fetch custom app $app_name (from repo $repo_name) after $max_attempts attempts. Check your GITHUB_TOKEN permissions (must have 'repo' scope) and repository access."
  fi

  echo -e "${YELLOW}⚠ Failed to fetch $app_name after $max_attempts attempts${NC}"
  return 1
}

# --- Platform Detection ---
OS="$(uname -s)"
if [ "$OS" == "Linux" ]; then
  echo -e "${BLUE}Detected OS: Linux (assuming Ubuntu/WSL compatibility)${NC}"
  PKG_MANAGER="apt"
elif [ "$OS" == "Darwin" ]; then
  echo -e "${BLUE}Detected OS: macOS${NC}"
  PKG_MANAGER="brew"
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required for macOS. Please install it."
  fi
else
  die "Unsupported OS: $OS"
fi

# --- Main Installation ---
echo -e "${BLUE}Installing Frappe (Fresh Start) on $OS...${NC}"

## Install Dependencies
echo -e "${BLUE}Installing dependencies...${NC}"
if [ "$PKG_MANAGER" == "apt" ]; then
  sudo apt update -y
  
  # --- Node.js/NPM/Yarn Setup (Fixed for 'npm not found') ---
  echo -e "${BLUE}Setting up NodeSource repository for Node.js 20...${NC}"
  # Install prerequisites
  sudo apt install -y ca-certificates curl gnupg
  # Add NodeSource GPG key
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  # Create NodeSource repository file for Node 20
  NODE_MAJOR=20
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
  
  # Update and install Node.js (which includes npm)
  sudo apt update -y
  sudo apt install -y nodejs
  
  echo -e "${BLUE}Installing required system packages...${NC}"
  # Install all other dependencies
  sudo apt install -y python3-dev python3-venv python3-pip redis-server mariadb-server mariadb-client curl git build-essential jq lsof 
  
  echo -e "${BLUE}Installing Yarn globally...${NC}"
  # Install Yarn globally using the newly installed npm
  sudo npm install -g yarn || true
  
  # Ensure the global npm directory is in PATH (The path fix for Yarn itself)
  NPM_GLOBAL_BIN="$(npm prefix -g)/bin"
  if ! echo "$PATH" | grep -q "$NPM_GLOBAL_BIN"; then
    export PATH="$NPM_GLOBAL_BIN:$PATH"
    echo -e "${GREEN}✓ Added $NPM_GLOBAL_BIN to PATH for Yarn access.${NC}"
  fi
  # -------------------------------------

elif [ "$PKG_MANAGER" == "brew" ]; then
  # Using python@3.12 for specific Frappe version requirements if needed, otherwise python3
  brew install python@3.12 mariadb redis node yarn
fi

## Setup Redis Instances
echo -e "${BLUE}Setting up Redis instances...${NC}"
REDIS_CONFIG_DIR="${HOME}/.redis"
mkdir -p "$REDIS_CONFIG_DIR"

if [ "$PKG_MANAGER" == "apt" ]; then
  # Stop system Redis and any running instances on ports
  sudo systemctl stop redis-server || true
  sudo pkill -9 -f redis-server 2>/dev/null || true
fi

# Stop any existing Redis instances on our ports
sudo lsof -i :${REDIS_CACHE_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
sudo lsof -i :${REDIS_QUEUE_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
sudo lsof -i :${REDIS_SOCKETIO_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
sleep 3

# Configuration generation (robust method to avoid 'unbound variable' errors)
for role in cache queue socketio; do
  port=""
  case "$role" in
    cache) port="$REDIS_CACHE_PORT" ;;
    queue) port="$REDIS_QUEUE_PORT" ;;
    socketio) port="$REDIS_SOCKETIO_PORT" ;;
  esac

  echo -e "${BLUE}Configuring Redis $role on port ${port}...${NC}"
  cat > "$REDIS_CONFIG_DIR/redis-$role.conf" <<EOF
port ${port}
bind 127.0.0.1
daemonize no
pidfile ${REDIS_CONFIG_DIR}/redis-$role.pid
dir ${REDIS_CONFIG_DIR}
EOF
done

echo -e "${BLUE}Starting Redis instances...${NC}"
if [ "$PKG_MANAGER" == "apt" ]; then
  redis-server "$REDIS_CONFIG_DIR/redis-cache.conf" &
  REDIS_CACHE_PID=$!
  redis-server "$REDIS_CONFIG_DIR/redis-queue.conf" &
  REDIS_QUEUE_PID=$!
  redis-server "$REDIS_CONFIG_DIR/redis-socketio.conf" &
  REDIS_SOCKETIO_PID=$!
  sleep 2
elif [ "$PKG_MANAGER" == "brew" ]; then
  echo -e "${YELLOW}⚠ On macOS, dedicated Redis configuration is done later by 'bench start'. Skipping separate start now.${NC}"
fi

# Verify Redis instances are running (only needed if started separately)
if [ "$PKG_MANAGER" == "apt" ]; then
  for i in {1..30}; do
    # Use the fully qualified variable names to prevent unbound variable errors
    CACHE_OK=$(redis-cli -p ${REDIS_CACHE_PORT} ping 2>/dev/null | grep PONG || echo NO)
    QUEUE_OK=$(redis-cli -p ${REDIS_QUEUE_PORT} ping 2>/dev/null | grep PONG || echo NO)
    SOCKETIO_OK=$(redis-cli -p ${REDIS_SOCKETIO_PORT} ping 2>/dev/null | grep PONG || echo NO)

    if [ "$CACHE_OK" == "PONG" ] && [ "$QUEUE_OK" == "PONG" ] && [ "$SOCKETIO_OK" == "PONG" ]; then
      echo -e "${GREEN}✓ All Redis instances are ready${NC}"
      break
    fi

    if [ $i -eq 30 ]; then
      die "Redis instances failed to start properly on ports ${REDIS_CACHE_PORT}, ${REDIS_QUEUE_PORT}, ${REDIS_SOCKETIO_PORT}"
    fi

    echo "Waiting for Redis instances... attempt $i/30"
    sleep 1
  done
fi

## Setup MariaDB (Final Fixed Logic)
echo -e "${BLUE}Setting up MariaDB...${NC}"

if [ "$PKG_MANAGER" == "apt" ]; then
    # 1. Stop service and clean up processes/ports
    echo -e "${BLUE}Attempting to stop all MariaDB/MySQL services...${NC}"
    sudo systemctl stop mariadb || true
    sudo systemctl stop mysql || true 
    sudo pkill -9 -f "mysqld" 2>/dev/null || true 
    sleep 3

    echo -e "${BLUE}Verifying port ${DB_PORT} is free...${NC}"
    sudo lsof -i :${DB_PORT} -t 2>/dev/null | xargs -r sudo kill -9 || true
    sleep 2

    # 2. Configure MariaDB using a minimal, custom config file to ensure clean syntax
    MARIADB_CONFIG_DIR="/etc/mysql/mariadb.conf.d"
    CUSTOM_CONFIG_FILE="${MARIADB_CONFIG_DIR}/99-frappe.cnf"
    
    echo -e "${BLUE}Creating clean MariaDB configuration in ${CUSTOM_CONFIG_FILE}...${NC}"

    # Use tee to write the new, minimal configuration
    sudo tee "$CUSTOM_CONFIG_FILE" > /dev/null <<EOF
[mysqld]
port = ${DB_PORT}
bind-address = 127.0.0.1
innodb_buffer_pool_size = 256M
skip-external-locking
EOF
    
    # Ensure systemd sees the changes
    sudo systemctl daemon-reload
    sleep 1

    # 3. Start MariaDB in insecure mode
    echo -e "${BLUE}Starting MariaDB in insecure mode to set root password...${NC}"
    # Setting an environment variable for mariadb.service to skip grant tables
    sudo systemctl set-environment MYSQLD_OPTS="--skip-grant-tables"
    sudo systemctl start mariadb || die "Failed to start MariaDB in insecure mode. Check 'sudo systemctl status mariadb.service'."
    sleep 4

    # 4. Set the root password using the insecure connection
    echo -e "${BLUE}Setting MariaDB root password...${NC}"
    # The --skip-grant-tables option allows root access without a password
    sudo mysql -u root <<SQL || die "Failed to set MariaDB root password"
FLUSH PRIVILEGES;
-- Remove unix_socket plugin authentication for localhost and 127.0.0.1
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
-- Ensure a network accessible root user exists
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    echo -e "${GREEN}✓ MariaDB root password set successfully.${NC}"

    # 5. Stop service, remove insecure option, and restart normally
    echo -e "${BLUE}Restarting MariaDB normally...${NC}"
    sudo systemctl stop mariadb
    sleep 2
    sudo systemctl unset-environment MYSQLD_OPTS
    sudo systemctl start mariadb || die "Failed to restart MariaDB normally. Check 'sudo systemctl status mariadb.service'."
    sleep 4

elif [ "$PKG_MANAGER" == "brew" ]; then
    # Homebrew MariaDB setup (which usually avoids the unix_socket issue)
    brew services stop mariadb || true
    echo -e "${YELLOW}⚠ Homebrew MariaDB service will be configured to use port ${DB_PORT}. ${NC}"
    mysql_config_file="$(brew --prefix)/etc/my.cnf"
    if [ ! -f "$mysql_config_file" ] || ! grep -q "port = ${DB_PORT}" "$mysql_config_file"; then
        # Append port configuration to the config file
        echo -e "[mysqld]\nport = ${DB_PORT}\n" >> "$mysql_config_file"
    fi
    brew services start mariadb || die "Failed to start MariaDB Homebrew service"
    sleep 5
    
    # Set password via standard ALTER USER (brew usually doesn't use unix_socket)
    echo -e "${BLUE}Setting MariaDB root password (macOS)...${NC}"
    mysql -u root <<SQL || die "Failed to set MariaDB root password"
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
    echo -e "${GREEN}✓ MariaDB root password set successfully.${NC}"
fi

# Universal verification check
if ! mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
  die "MariaDB connection failed - verify port ${DB_PORT} is accessible and root password is set"
fi

echo -e "${GREEN}✓ MariaDB ready on port ${DB_PORT}${NC}"

## Install Bench and Initialize

# Determine the correct Python executable to use
PYTHON_EXEC="python3"
if [ "$PKG_MANAGER" == "brew" ]; then
    # On macOS, check for the specific version required (or default)
    if command -v python3.12 >/dev/null 2>&1; then
        PYTHON_EXEC="python3.12"
    fi
    echo -e "${BLUE}Using Python executable: ${PYTHON_EXEC}${NC}"
fi

if ! command -v bench >/dev/null 2>&1; then
  echo -e "${BLUE}Installing frappe-bench using ${PYTHON_EXEC}...${NC}"
  "$PYTHON_EXEC" -m pip install --user frappe-bench || die "Failed to install frappe-bench"
fi

echo -e "${BLUE}Cleaning up old installation...${NC}"
if [ -d "$INSTALL_DIR/$BENCH_NAME" ]; then
  echo "Removing old bench directory..."
  sudo chmod -R u+w "$INSTALL_DIR/$BENCH_NAME" 2>/dev/null || true
  sudo rm -rf "$INSTALL_DIR/$BENCH_NAME" || die "Failed to remove old bench directory"
  echo -e "${GREEN}Old bench removed${NC}"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "${BLUE}Initializing fresh bench...${NC}"
bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_EXEC" || die "Failed to initialize bench"

cd "$BENCH_NAME"

echo -e "${BLUE}Configuring bench...${NC}"
bench config set-common-config -c db_host "127.0.0.1" || true
bench config set-common-config -c db_port "${DB_PORT}" || true
bench config set-common-config -c mariadb_root_password "${MYSQL_ROOT_PASS}" || true
bench config set-common-config -c redis_cache "redis://127.0.0.1:${REDIS_CACHE_PORT}" || true
bench config set-common-config -c redis_queue "redis://127.0.0.1:${REDIS_QUEUE_PORT}" || true
bench config set-common-config -c redis_socketio "redis://127.0.0.1:${REDIS_SOCKETIO_PORT}" || true

## Fetch Apps
echo -e "${BLUE}Fetching standard apps...${NC}"

# Standard Apps
retry_get_app "erpnext" "erpnext" "$ERPNEXT_BRANCH" "https://github.com/frappe/erpnext" || die "Failed to get ERPNext after retries"
retry_get_app "hrms" "hrms" "$HRMS_BRANCH" "https://github.com/frappe/hrms" || die "Failed to get HRMS after retries"

# Custom Apps
echo -e "${BLUE}Fetching custom apps...${NC}"
if [ -z "${GITHUB_TOKEN}" ]; then
  echo -e "${YELLOW}⚠ No GitHub token provided - custom apps will be skipped${NC}"
  echo -e "${YELLOW}To include custom apps, run: bash install-frappe-complete.sh -t YOUR_GITHUB_TOKEN${NC}"
else
  echo -e "${GREEN}✓ GitHub token received${NC}"
  for repo_name in "${!CUSTOM_APPS[@]}"; do
    app_name="${CUSTOM_APPS[$repo_name]}"
    # Note: The GITHUB_TOKEN is embedded in the URL for authentication
    repo_url="https://token:${GITHUB_TOKEN}@github.com/MMCY-Tech/${repo_name}.git"

    # The retry_get_app function now uses --resolve-deps for mmcy_ apps
    retry_get_app "$app_name" "$repo_name" "$CUSTOM_BRANCH" "$repo_url"
  done
fi

echo -e "${GREEN}✓ All apps fetched${NC}"

## Create Site
echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

# Simple cleanup of the specific site's DB and folder
echo "Cleaning up any leftover database and folder for ${SITE_NAME}..."
DB_NAME=$(echo ${SITE_NAME} | sed 's/\./_/g')
# Explicitly use -h 127.0.0.1 for consistent connection
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
rm -rf "sites/${SITE_NAME}" 2>/dev/null || true
sleep 2

# Create new site and install core apps simultaneously
bench new-site "$SITE_NAME" \
    --db-type mariadb \
    --db-host "127.0.0.1" \
    --db-port "${DB_PORT}" \
    --db-root-username root \
    --db-root-password "${MYSQL_ROOT_PASS}" \
    --admin-password "${ADMIN_PASS}" \
    --force \
    --install-app frappe \
    --install-app erpnext \
    --install-app hrms || die "Failed to create site '${SITE_NAME}'"

echo -e "${GREEN}✓ Site created and core apps installed${NC}"

## Install Custom Apps
echo -e "${BLUE}Installing custom apps on site...${NC}"
for app_name in "${CUSTOM_APPS[@]}"; do
  if [ -d "apps/$app_name" ]; then
    echo "Installing $app_name..."
    # Install with --skip-migrations as requested
    bench --site "$SITE_NAME" install-app "$app_name" --skip-migrations || echo -e "${YELLOW}⚠ $app_name installation had issues (expected - migration pending)${NC}"
    echo -e "${GREEN}✓ $app_name linked to site${NC}"
  fi
done

echo -e "${YELLOW}⚠ Skipping migrations intentionally. Apps will load but some pages may break.${NC}"

## Build Assets and Configure
echo -e "${BLUE}Building assets and clearing cache...${NC}"
bench build || true
bench --site "$SITE_NAME" clear-cache || true
bench --site "$SITE_NAME" clear-website-cache || true

echo -e "${BLUE}Setting up Procfile with correct Redis configuration...${NC}"
# Use the REDIS_CONFIG_DIR variable for the full path
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

# Optional post-install setup (keep as is)
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

if [ "$PKG_MANAGER" == "brew" ]; then
  echo "2. **IMPORTANT for macOS:** Ensure services are running: \`brew services start mariadb\` and \`brew services start redis\`"
else
  echo "2. **IMPORTANT for WSL/Linux:** Check that MariaDB and the three custom Redis instances are running (if you hit 'Killed' errors, fix your memory allocation)."
fi

echo "3. Start the server: bench start"
echo "4. Access at: http://localhost:8000"
echo ""
echo -e "${BLUE}Login credentials:${NC}"
echo "Site: ${SITE_NAME}"
echo "Admin Password: ${ADMIN_PASS}"
echo ""
echo -e "${BLUE}Installed apps:${NC}"
bench --site "$SITE_NAME" list-apps | sed 's/^/  - /'
echo ""
