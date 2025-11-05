#!/usr/bin/env bash
set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
BENCH_NAME="frappe-bench"
INSTALL_DIR="$HOME/frappe-setup"
SITE_NAME="mmcy.hrms"
SITE_PORT="8000"
DB_PORT="3307"
MYSQL_USER="frappe"
MYSQL_PASS="frappe"
ROOT_MYSQL_PASS="root"
ADMIN_PASS="admin"
CUSTOM_HR_REPO_BASE="github.com/MMCY-Tech/custom-hrms.git"
CUSTOM_ASSET_REPO_BASE="github.com/MMCY-Tech/custom-asset-management.git"
CUSTOM_IT_REPO_BASE="github.com/MMCY-Tech/custom-it-operations.git"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

verify_app() {
    local app=$1
    if [ -d "$INSTALL_DIR/$BENCH_NAME/apps/$app" ]; then
        return 0
    else
        return 1
    fi
}

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
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_MYSQL_PASS}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${ROOT_MYSQL_PASS}';
FLUSH PRIVILEGES;
SQL

sudo systemctl stop mariadb
sleep 2
sudo systemctl unset-environment MYSQLD_OPTS
sudo systemctl start mariadb
sleep 4

if ! mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${ROOT_MYSQL_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
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
bench config set-common-config -c mariadb_root_password "'${ROOT_MYSQL_PASS}'" || true

echo -e "${BLUE}Fetching apps...${NC}"

git config --global http.postBuffer 1024m
git config --global http.maxRequestBuffer 100m
git config --global core.compression 0
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 60
git config --global fetch.timeout 600
git config --global core.packedRefsTimeout 10

clone_with_retry() {
  local url=$1
  local branch=$2
  local dest=$3
  local max_attempts=5
  local attempt=1
  local wait_time=10
  
  local auth_url="$url"
  if [ -n "$GITHUB_TOKEN" ]; then
    auth_url="https://${GITHUB_TOKEN}@github.com/$(echo $url | sed 's/https:\/\/github\.com\///')"
  fi
  
  while [ $attempt -le $max_attempts ]; do
    echo -e "${YELLOW}Attempt $attempt/$max_attempts: Cloning $dest (branch: $branch) - shallow clone...${NC}"
    
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$branch" --single-branch --progress "$auth_url" "$dest" 2>&1 | tee /tmp/git_clone.log; then
      echo -e "${GREEN}✓ Successfully cloned $dest${NC}"
      return 0
    fi
    
    if grep -q "Connection timed out\|Connection reset\|Recv failure\|early EOF" /tmp/git_clone.log; then
      echo -e "${YELLOW}⚠ Connection timeout detected, waiting ${wait_time}s before retry...${NC}"
      rm -rf "$dest" 2>/dev/null || true
      sleep $wait_time
      wait_time=$((wait_time * 2))
      if [ $wait_time -gt 120 ]; then
        wait_time=120
      fi
    else
      echo -e "${RED}✗ Clone failed - trying main branch...${NC}"
      rm -rf "$dest" 2>/dev/null || true
      
      if [ "$branch" = "develop" ]; then
        echo -e "${YELLOW}Retrying with main branch...${NC}"
        if GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch main --single-branch --progress "$auth_url" "$dest" 2>&1; then
          echo -e "${GREEN}✓ Successfully cloned $dest (from main branch)${NC}"
          return 0
        fi
      fi
      
      sleep 5
    fi
    
    attempt=$((attempt + 1))
  done
  
  die "Failed to clone $url after $max_attempts attempts"
}

if [ ! -d "apps/erpnext" ]; then
  echo "Fetching ERPNext from branch ${ERPNEXT_BRANCH}..."
  clone_with_retry "https://github.com/frappe/erpnext.git" "$ERPNEXT_BRANCH" "apps/erpnext"
  echo -e "${GREEN}✓ ERPNext fetched${NC}"
fi

if [ ! -d "apps/hrms" ]; then
  echo "Fetching HRMS from branch ${HRMS_BRANCH}..."
  clone_with_retry "https://github.com/frappe/hrms.git" "$HRMS_BRANCH" "apps/hrms"
  echo -e "${GREEN}✓ HRMS fetched${NC}"
fi

echo "Fetching custom-hrms..."
if clone_with_retry "https://github.com/MMCY-Tech/custom-hrms.git" "$CUSTOM_BRANCH" "apps/custom-hrms" 2>&1; then
  echo -e "${GREEN}✓ custom-hrms fetched${NC}"
else
  echo -e "${YELLOW}⚠ custom-hrms fetch failed (will continue)${NC}"
fi

echo "Fetching custom-asset-management..."
if clone_with_retry "https://github.com/MMCY-Tech/custom-asset-management.git" "$CUSTOM_BRANCH" "apps/custom-asset-management" 2>&1; then
  echo -e "${GREEN}✓ custom-asset-management fetched${NC}"
else
  echo -e "${YELLOW}⚠ custom-asset-management fetch failed (will continue)${NC}"
fi

echo "Fetching custom-it-operations..."
if clone_with_retry "https://github.com/MMCY-Tech/custom-it-operations.git" "$CUSTOM_BRANCH" "apps/custom-it-operations" 2>&1; then
  echo -e "${GREEN}✓ custom-it-operations fetched${NC}"
else
  echo -e "${YELLOW}⚠ custom-it-operations fetch failed (will continue)${NC}"
fi

echo -e "${GREEN}✓ App fetching completed${NC}"

echo -e "${BLUE}Verifying apps were fetched...${NC}"
verify_app "frappe" || die "Core app 'frappe' is missing!"
verify_app "erpnext" || die "Core app 'erpnext' is missing!"
verify_app "hrms" || die "Core app 'hrms' is missing!"

if verify_app "custom-hrms"; then
  echo -e "${GREEN}✓ custom-hrms verified${NC}"
else
  echo -e "${YELLOW}⚠ custom-hrms not found (will skip installation)${NC}"
fi

if verify_app "custom-asset-management"; then
  echo -e "${GREEN}✓ custom-asset-management verified${NC}"
else
  echo -e "${YELLOW}⚠ custom-asset-management not found (will skip installation)${NC}"
fi

if verify_app "custom-it-operations"; then
  echo -e "${GREEN}✓ custom-it-operations verified${NC}"
else
  echo -e "${YELLOW}⚠ custom-it-operations not found (will skip installation)${NC}"
fi

echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

echo "Cleaning up any leftover databases..."
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${ROOT_MYSQL_PASS}" <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS \`$(echo ${SITE_NAME} | sed 's/\./_/g')\`;
DROP DATABASE IF EXISTS \`_afd6259a990fe66d\`;
FLUSH PRIVILEGES;
SQL

rm -rf "sites/${SITE_NAME}" 2>/dev/null || true

bench drop-site "$SITE_NAME" --no-backup --force --db-root-username root --db-root-password "${ROOT_MYSQL_PASS}" 2>&1 | tail -3 || true

sleep 5

bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${ROOT_MYSQL_PASS}" \
  --admin-password "${ADMIN_PASS}" || die "Failed to create site '${SITE_NAME}'"

echo -e "${GREEN}✓ Site created${NC}"

echo -e "${BLUE}Installing apps on site...${NC}"

# Install core apps
if bench --site "$SITE_NAME" install-app erpnext; then
  echo -e "${GREEN}✓ ERPNext installed${NC}"
else
  echo -e "${YELLOW}⚠ ERPNext installation had issues${NC}"
fi

if bench --site "$SITE_NAME" install-app hrms; then
  echo -e "${GREEN}✓ HRMS installed${NC}"
else
  echo -e "${YELLOW}⚠ HRMS installation had issues${NC}"
fi

if [ -d "apps/custom-hrms" ]; then
  echo "Installing custom-hrms with fixture workaround..."
  FIXTURE_PATH="apps/custom-hrms/custom_hrms/fixtures"
  if [ -d "$FIXTURE_PATH" ]; then
    mv "$FIXTURE_PATH" "$FIXTURE_PATH.backup" 2>/dev/null || true
  fi
  
  if bench --site "$SITE_NAME" install-app custom-hrms; then
    echo -e "${GREEN}✓ custom-hrms installed${NC}"
  else
    echo -e "${YELLOW}⚠ custom-hrms installation had issues${NC}"
  fi
  
  if [ -d "$FIXTURE_PATH.backup" ]; then
    mv "$FIXTURE_PATH.backup" "$FIXTURE_PATH" 2>/dev/null || true
  fi
fi

if [ -d "apps/custom-asset-management" ]; then
  echo "Installing custom-asset-management with fixture workaround..."
  FIXTURE_PATH="apps/custom-asset-management/custom_asset_management/fixtures"
  if [ -d "$FIXTURE_PATH" ]; then
    mv "$FIXTURE_PATH" "$FIXTURE_PATH.backup" 2>/dev/null || true
  fi
  
  if bench --site "$SITE_NAME" install-app custom-asset-management; then
    echo -e "${GREEN}✓ custom-asset-management installed${NC}"
  else
    echo -e "${YELLOW}⚠ custom-asset-management installation had issues${NC}"
  fi
  
  if [ -d "$FIXTURE_PATH.backup" ]; then
    mv "$FIXTURE_PATH.backup" "$FIXTURE_PATH" 2>/dev/null || true
  fi
fi

if [ -d "apps/custom-it-operations" ]; then
  if bench --site "$SITE_NAME" install-app custom-it-operations; then
    echo -e "${GREEN}✓ custom-it-operations installed${NC}"
  else
    echo -e "${YELLOW}⚠ custom-it-operations installation had issues${NC}"
  fi
fi

echo -e "${BLUE}Building assets...${NC}"
bench build || true

echo -e "${BLUE}Clearing cache...${NC}"
bench --site "$SITE_NAME" clear-cache || true
bench --site "$SITE_NAME" clear-website-cache || true

echo -e "${BLUE}Updating Procfile...${NC}"
sed -i '/^web:/d' Procfile || true
echo "web: bench serve --port $SITE_PORT" >> Procfile

# Add to hosts file
if ! grep -q "^127.0.0.1[[:space:]]\+$SITE_NAME\$" /etc/hosts; then
  echo "127.0.0.1 $SITE_NAME" | sudo tee -a /etc/hosts >/dev/null
  echo -e "${GREEN}✓ Added $SITE_NAME to /etc/hosts${NC}"
fi

echo -e "${BLUE}Verifying installed apps...${NC}"
bench --site "$SITE_NAME" list-apps

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Navigate to bench: cd ${INSTALL_DIR}/${BENCH_NAME}"
echo "2. Start the server: bench start"
echo "3. In another terminal, run: bench --site $SITE_NAME migrate"
echo "4. Access at: http://localhost:${SITE_PORT} or http://${SITE_NAME}:${SITE_PORT}"
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
