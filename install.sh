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
  # Using python3 instead of python3.12 for wider compatibility
  sudo apt install -y python3-dev python3-venv python3-pip redis-server mariadb-server mariadb-client curl git build-essential nodejs jq lsof # Added lsof
  sudo npm install -g yarn || true
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

## Setup MariaDB (ULTRA ROBUST FIXED SECTION)
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

    # 3. Start MariaDB normally
    echo -e "${BLUE}Starting MariaDB on port ${DB_PORT}...${NC}"
    # Start the service and wait for it to be active
    sudo systemctl start mariadb 
    
    for i in {1..15}; do
        if sudo systemctl is-active mariadb >/dev/null 2>&1; then
            echo -e "${GREEN}✓ MariaDB service is running${NC}"
            break
        fi
        if [ $i -eq 15 ]; then
             die "MariaDB service failed to start after configuration. Run 'sudo systemctl status mariadb.service' for the error. Check for low memory on WSL."
        fi
        echo "Waiting for MariaDB service to become active... attempt $i/15"
        sleep 2
    done

    # 4. Set the root password leveraging the unix_socket plugin for initial authentication
    echo -e "${BLUE}Setting MariaDB root password and fixing authentication...${NC}"
    # Connect as root using the OS user (unix_socket)
    sudo mysql <<SQL || die "Failed to set MariaDB root password"
-- Remove the unix_socket plugin for root@localhost and set password
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
-- Create or alter user for '127.0.0.1' and grant privileges
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
-- Create or alter user for '::1' (IPv6) and grant privileges
CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    echo -e "${GREEN}✓ MariaDB root password set successfully.${NC}"

    # 5. Restart MariaDB to ensure new credentials are used
    sudo systemctl restart mariadb
    sleep 3

elif [ "$PKG_MANAGER" == "brew" ]; then
    # Homebrew MariaDB setup 
    brew services stop mariadb || true
    echo
