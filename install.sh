#!/bin/bash
# =====================================================================
#  FULL AUTOMATED FRAPPE/ERPNext INSTALLER WITH CUSTOM APPS (v15)
#  Compatible with Ubuntu 22.04 LTS
# =====================================================================

set -e

# -------------------------------
# CONFIGURATION VARIABLES
# -------------------------------
FRAPPE_USER="frappe"
FRAPPE_HOME="/home/$FRAPPE_USER"
BENCH_DIR="$FRAPPE_HOME/frappe-bench"
SITE_NAME="site1.local"
ADMIN_PASSWORD="admin"
MYSQL_ROOT_PASSWORD="frappe"
FRAPPE_BRANCH="version-15"

# -------------------------------
# 1. SYSTEM PREPARATION
# -------------------------------
echo "---- [1/8] Updating system packages ----"
sudo apt update -y && sudo apt upgrade -y

echo "---- [2/8] Installing dependencies ----"
sudo apt install -y python3-dev python3-pip python3-venv python3-testresources \
  build-essential git curl redis-server software-properties-common \
  wkhtmltopdf xvfb libfontconfig libxrender1 libjpeg-dev libx11-dev libxext6 \
  xfonts-75dpi xfonts-base fontconfig mariadb-server mariadb-client \
  libmysqlclient-dev nginx supervisor

# -------------------------------
# 2. NODE & YARN
# -------------------------------
echo "---- [3/8] Installing NodeJS 18.x and Yarn ----"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g yarn

# -------------------------------
# 3. DATABASE SETUP (FIXED)
# -------------------------------
echo "---- [4/8] Configuring MariaDB ----"
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Use unix_socket authentication to execute root SQL commands directly
sudo mysql <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS 'frappe'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'frappe'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Optimize MySQL for ERPNext
sudo bash -c 'cat > /etc/mysql/conf.d/frappe.cnf' <<EOL
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[client]
default-character-set = utf8mb4
EOL

sudo systemctl restart mariadb

# -------------------------------
# 4. FRAPPE USER SETUP
# -------------------------------
echo "---- [5/8] Creating frappe user ----"
if ! id "$FRAPPE_USER" &>/dev/null; then
  sudo adduser --disabled-password --gecos "" $FRAPPE_USER
  sudo usermod -aG sudo $FRAPPE_USER
fi

# -------------------------------
# 5. BENCH INITIALIZATION
# -------------------------------
echo "---- [6/8] Installing Bench ----"
sudo -H -u $FRAPPE_USER bash << 'EOF'
set -e
cd ~

# Install bench
pip3 install frappe-bench --break-system-packages

# Initialize bench environment
bench init frappe-bench --frappe-branch version-15 --ignore-exist
cd frappe-bench

# Create new site
bench new-site site1.local --mariadb-root-password frappe --admin-password admin --no-mariadb-socket

# -------------------------------
# 6. GET OFFICIAL APPS
# -------------------------------
bench get-app erpnext https://github.com/frappe/erpnext --branch version-15
bench get-app hrms https://github.com/frappe/hrms --branch version-15

# -------------------------------
# 7. GET CUSTOM APPS
# -------------------------------
bench get-app custom_hrms https://github.com/mmcytech/custom-hrms.git
bench get-app custom_asset_management https://github.com/mmcytech/custom-asset-management.git
bench get-app custom_it_operations https://github.com/mmcytech/custom-it-operations.git

# -------------------------------
# 8. INSTALL APPS TO SITE
# -------------------------------
bench --site site1.local install-app erpnext
bench --site site1.local install-app hrms
bench --site site1.local install-app custom_hrms
bench --site site1.local install-app custom_asset_management
bench --site site1.local install-app custom_it_operations

# Build frontend and restart bench
bench build
bench restart

EOF

# -------------------------------
# FINAL MESSAGE
# -------------------------------
echo "=================================================================="
echo "✅ ERPNext + HRMS + Custom Apps Installed Successfully!"
echo "Login at: http://localhost:8000"
echo "Username: Administrator | Password: ${ADMIN_PASSWORD}"
echo "=================================================================="
echo "To start bench manually, run:"
echo "    sudo -H -u ${FRAPPE_USER} bash -c 'cd ${BENCH_DIR} && bench start'"
echo "=================================================================="
