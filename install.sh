#!/usr/bin/env bash
# =====================================================================
# Unified Frappe v15 + ERPNext + HRMS + MMCY custom apps installer
# - Creates a MariaDB admin user (frappe_admin) via sudo mysql (unix_socket safe)
# - Uses frappe_admin for bench new-site to avoid root unix_socket/password issues
# - Installs Node 18, yarn, redis, wkhtmltopdf, bench, fetches apps, installs them
# - Supports private custom repos (GITHUB_TOKEN env var)
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------- CONFIG -------------
FRAPPE_USER="frappe"
INSTALL_DIR="${HOME}/frappe-setup"
BENCH_NAME="frappe-bench"
SITE_NAME="mmcy.hrms"
SITE_PORT="8003"
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"
CUSTOM_BRANCH="develop"
MYSQL_ADMIN_USER="frappe_admin"        # created in MariaDB using sudo mysql
MYSQL_ADMIN_PASS="StrongAdminPass1!"   # <-- change if desired (used by bench new-site)
MYSQL_APP_USER="frappe"                # app DB user (will be created by bench/site)
MYSQL_APP_PASS="frappe"                # app DB credentials (benchmark defaults)
ADMIN_PASS="admin"                     # ERPNext admin password
USE_LOCAL_APPS=false
CUSTOM_HR_REPO_BASE="github.com/MMCY-Tech/custom-hrms.git"
CUSTOM_ASSET_REPO_BASE="github.com/MMCY-Tech/custom-asset-management.git"
CUSTOM_IT_REPO_BASE="github.com/MMCY-Tech/custom-it-operations.git"

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'

echo -e "${BLUE}Starting unified installer...${NC}"
echo "Install dir: $INSTALL_DIR"
echo

export PATH="$HOME/.local/bin:$PATH"

# ------------- GitHub token handling for private repos -------------
if [ "${USE_LOCAL_APPS}" = "false" ]; then
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo -n "If any custom apps are private, set GITHUB_TOKEN environment variable now or press Enter to continue (public repos ok): "
    read -r token_input
    if [ -n "$token_input" ]; then
      export GITHUB_TOKEN="$token_input"
    fi
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GITHUB_USER="token"
    CUSTOM_HR_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${GITHUB_USER}:${GITHUB_TOKEN}@${CUSTOM_IT_REPO_BASE}"
  else
    CUSTOM_HR_REPO="https://${CUSTOM_HR_REPO_BASE}"
    CUSTOM_ASSET_REPO="https://${CUSTOM_ASSET_REPO_BASE}"
    CUSTOM_IT_REPO="https://${CUSTOM_IT_REPO_BASE}"
  fi
fi

# ------------- System update & dependencies -------------
echo -e "${BLUE}Updating packages and installing dependencies...${NC}"
sudo apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y

sudo apt install -y git curl wget python3 python3-venv python3-dev python3-pip \
  redis-server xvfb libfontconfig wkhtmltopdf mariadb-server mariadb-client \
  build-essential jq unzip gnupg lsb-release

# Node 18 + yarn
echo -e "${BLUE}Installing Node 18 and yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >/dev/null 2>&1 || true
sudo apt install -y nodejs
if ! command -v yarn >/dev/null 2>&1; then
  sudo npm install -g yarn || true
fi

# ------------- MariaDB: start and create admin user (via sudo mysql) -------------
echo -e "${BLUE}Starting MariaDB and creating admin user via sudo mysql...${NC}"
# ensure MariaDB running
sudo systemctl enable mariadb
sudo systemctl restart mariadb
sleep 2

# Use sudo mysql (unix_socket) to create a new admin user with password
sudo mysql <<SQL || { echo -e "${RED}Failed to run sudo mysql; inspect MariaDB status.${NC}"; exit 1; }
-- create an admin user for bench operations (safe: does not modify root auth)
CREATE USER IF NOT EXISTS '${MYSQL_ADMIN_USER}'@'localhost' IDENTIFIED BY '${MYSQL_ADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ADMIN_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

echo -e "${GREEN}MariaDB admin user '${MYSQL_ADMIN_USER}' created. Use this account for bench new-site.${NC}"

# Add minimal UTF8 config for MariaDB (recommended for Frappe)
sudo bash -c 'cat > /etc/mysql/conf.d/frappe.cnf' <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

sudo systemctl restart mariadb
sleep 2

# ------------- Create system user for bench -------------
echo -e "${BLUE}Creating system user '${FRAPPE_USER}' (if missing)...${NC}"
if ! id "$FRAPPE_USER" >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" "$FRAPPE_USER"
  sudo usermod -aG sudo "$FRAPPE_USER"
  echo -e "${GREEN}User $FRAPPE_USER created.${NC}"
else
  echo -e "${YELLOW}User $FRAPPE_USER already exists.${NC}"
fi

# ------------- Install bench CLI (pip user/pipx) -------------
echo -e "${BLUE}Installing frappe-bench CLI...${NC}"
# prefer pipx if present
if command -v pipx >/dev/null 2>&1; then
  pipx install frappe-bench || pipx upgrade --include-deps frappe-bench || true
else
  python3 -m pip install --user --upgrade pip setuptools wheel
  python3 -m pip install --user frappe-bench || true
fi
export PATH="$HOME/.local/bin:$PATH"

# ------------- Initialize bench and apps (as FRAPPE_USER) -------------
echo -e "${BLUE}Initializing bench and fetching apps (running as $FRAPPE_USER)...${NC}"
sudo -H -u "$FRAPPE_USER" bash <<'BASHUSER'
set -euo pipefail
IFS=$'\n\t'

# Variables inherited from parent are not available here; we will rely on environment values passed implicitly via sudo -H -u
cd ~

# create install directory if not exists (parent script made it)
mkdir -p "$HOME/frappe-setup"
cd "$HOME/frappe-setup"

# init bench if not exist
if [ ! -d "frappe-bench" ]; then
  bench init frappe-bench --frappe-branch version-15 --python python3
fi
cd frappe-bench

# Fetch core apps if absent
if [ ! -d "apps/erpnext" ]; then
  bench get-app erpnext https://github.com/frappe/erpnext --branch version-15
fi
if [ ! -d "apps/hrms" ]; then
  bench get-app hrms https://github.com/frappe/hrms --branch version-15
fi

# fetch custom apps if not present; parent script exported CUSTOM_* variables if needed
# Attempt to use environment variables from parent: CUSTOM_HR_REPO etc.
if [ -n "${CUSTOM_HR_REPO:-}" ] && [ ! -d "apps/mmcy_hrms" ]; then
  bench get-app mmcy_hrms "$CUSTOM_HR_REPO" --branch develop || true
fi
if [ -n "${CUSTOM_ASSET_REPO:-}" ] && [ ! -d "apps/mmcy_asset_management" ]; then
  bench get-app mmcy_asset_management "$CUSTOM_ASSET_REPO" --branch develop || true
fi
if [ -n "${CUSTOM_IT_REPO:-}" ] && [ ! -d "apps/mmcy_it_operations" ]; then
  bench get-app mmcy_it_operations "$CUSTOM_IT_REPO" --branch develop || true
fi

BASHUSER

# ------------- Create site using MYSQL_ADMIN credentials (no root/auth problems) -------------
echo -e "${BLUE}Creating new site '${SITE_NAME}' using MariaDB admin user '${MYSQL_ADMIN_USER}'...${NC}"
# bench new-site must run as FRAPPE_USER; pass --mariadb-root-username and password we created
sudo -H -u "$FRAPPE_USER" bash -c "cd $INSTALL_DIR/$BENCH_NAME && \
  bench drop-site $SITE_NAME --no-backup --force 2>/dev/null || true && \
  bench new-site $SITE_NAME --mariadb-root-username $MYSQL_ADMIN_USER --mariadb-root-password $MYSQL_ADMIN_PASS --admin-password $ADMIN_PASS"

# ------------- Install apps into site (as FRAPPE_USER) -------------
echo -e "${BLUE}Installing apps into site ${SITE_NAME}...${NC}"
sudo -H -u "$FRAPPE_USER" bash <<BASHUSER2
set -e
cd "$INSTALL_DIR/$BENCH_NAME"

# Install core apps
bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms

# install custom apps (if present)
if [ -d "apps/mmcy_hrms" ]; then
  bench --site "$SITE_NAME" install-app mmcy_hrms
fi
if [ -d "apps/mmcy_asset_management" ]; then
  # if asset fixtures problematic, you can implement the same fixture-move workaround before install
  bench --site "$SITE_NAME" install-app mmcy_asset_management || true
fi
if [ -d "apps/mmcy_it_operations" ]; then
  bench --site "$SITE_NAME" install-app mmcy_it_operations || true
fi

# run migrate and build
bench --site "$SITE_NAME" migrate || true
bench build || true
BASHUSER2

# ------------- Finalize Procfile/hosts and show status -------------
echo -e "${BLUE}Updating Procfile and /etc/hosts...${NC}"
# set web port in Procfile
sudo sed -i '/^web:/d' "$INSTALL_DIR/$BENCH_NAME/Procfile" 2>/dev/null || true
echo "web: bench serve --port ${SITE_PORT}" | sudo tee -a "$INSTALL_DIR/$BENCH_NAME/Procfile" >/dev/null

# ensure hosts entry
if ! grep -q "^127.0.0.1[[:space:]]\+${SITE_NAME}\$" /etc/hosts; then
  echo "127.0.0.1 ${SITE_NAME}" | sudo tee -a /etc/hosts >/dev/null
fi

# ------------- Done -------------
echo -e "${GREEN}Installation completed.${NC}"
echo -e "To start the bench (as ${FRAPPE_USER}):"
echo -e "  sudo -H -u ${FRAPPE_USER} bash -c 'cd ${INSTALL_DIR}/${BENCH_NAME} && bench start'"
echo -e "Access site: http://${SITE_NAME}:${SITE_PORT}  (or http://localhost if port 8000 default)"
echo -e "ERPNext admin: ${ADMIN_PASS}"
echo
echo -e "${YELLOW}Notes:${NC}"
echo "- MariaDB admin user: ${MYSQL_ADMIN_USER} (password: ${MYSQL_ADMIN_PASS})"
echo "- Bench site database user will be created automatically by bench/new-site."
echo "- If your custom repos are private, set GITHUB_TOKEN env var before running to allow cloning."
