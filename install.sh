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
  
  while [ $attempt -le $max_attempts ]; do
    echo -e "${YELLOW}Attempt $attempt/$max_attempts: Cloning $url (branch: $branch)...${NC}"
    
    # Try with --depth 1 first (faster)
    if GIT_TRACE=1 git clone --depth 1 --branch "$branch" --single-branch --progress "$url" "$dest" 2>&1 | tee /tmp/git_clone.log; then
      echo -e "${GREEN}✓ Successfully cloned $dest${NC}"
      return 0
    fi
    
    # Check if it's a timeout/connection error
    if grep -q "Connection timed out\|Connection reset\|Recv failure\|early EOF" /tmp/git_clone.log; then
      echo -e "${YELLOW}⚠ Connection timeout detected, waiting ${wait_time}s before retry...${NC}"
      rm -rf "$dest" 2>/dev/null || true
      sleep $wait_time
      # Exponential backoff
      wait_time=$((wait_time * 2))
      if [ $wait_time -gt 120 ]; then
        wait_time=120
      fi
    else
      echo -e "${RED}✗ Clone failed with non-timeout error${NC}"
      cat /tmp/git_clone.log
      rm -rf "$dest" 2>/dev/null || true
      sleep 5
    fi
    
    attempt=$((attempt + 1))
  done
  
  echo -e "${YELLOW}Git clone failed, attempting fallback method (downloading zip)...${NC}"
  
  local zip_url="${url%.git}/archive/refs/heads/${branch}.zip"
  local zip_file="/tmp/${dest##*/}.zip"
  
  if command -v wget >/dev/null 2>&1; then
    if wget --timeout=60 --tries=3 -O "$zip_file" "$zip_url" 2>&1; then
      mkdir -p "$dest"
      unzip -q "$zip_file" -d "$dest"
      # Move contents up one level (zip creates a subfolder)
      local subfolder=$(ls -d "$dest"/*/ | head -1)
      if [ -n "$subfolder" ]; then
        mv "$subfolder"/* "$dest/"
        rmdir "$subfolder"
      fi
      rm -f "$zip_file"
      echo -e "${GREEN}✓ Successfully downloaded and extracted $dest${NC}"
      return 0
    fi
  fi
  
  die "Failed to clone or download $url after $max_attempts attempts"
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

echo -e "${GREEN}✓ All apps fetched${NC}"

echo -e "${BLUE}Creating site '${SITE_NAME}'...${NC}"

echo "Cleaning up any leftover databases..."
mysql --protocol=TCP -h 127.0.0.1 -P ${DB_PORT} -u root -p"${MYSQL_ROOT_PASS}" <<SQL 2>/dev/null || true
-- Drop any leftover databases for this site
DROP DATABASE IF EXISTS \`$(echo ${SITE_NAME} | sed 's/\./_/g')\`;
-- Drop any temporary databases that might exist
DROP DATABASE IF EXISTS \`_afd6259a990fe66d\`;
FLUSH PRIVILEGES;
SQL

# Remove site directory if it exists
rm -rf "sites/${SITE_NAME}" 2>/dev/null || true

# Try to drop existing site (ignore errors)
bench drop-site "$SITE_NAME" --no-backup --force --db-root-username root --db-root-password "${MYSQL_ROOT_PASS}" 2>&1 | tail -3 || true

# Create new site with proper parameters for version-15
bench new-site "$SITE_NAME" \
  --db-type mariadb \
  --db-host "127.0.0.1" \
  --db-port "${DB_PORT}" \
  --db-root-username root \
  --db-root-password "${MYSQL_ROOT_PASS}" \
  --admin-password "${ADMIN_PASS}" || die "Failed to create site '${SITE_NAME}'"

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
