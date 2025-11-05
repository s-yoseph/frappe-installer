#!/bin/bash
# =====================================================================
#  FULL AUTOMATED FRAPPE/ERPNext INSTALLER (v15)
#  with Custom Apps and Proper MariaDB Handling
#  Works on Ubuntu 22.04 LTS
# =====================================================================

set -e
LOGFILE="/tmp/frappe_install_$(date +%F_%T).log"
exec > >(tee -a "$LOGFILE") 2>&1

# -------------------------------
# CONFIGURATION
# -------------------------------
FRAPPE_USER="frappe"
FRAPPE_HOME="/home/$FRAPPE_USER"
BENCH_DIR="$FRAPPE_HOME/frappe-bench"
SITE_NAME="site1.local"
ADMIN_PASSWORD="admin"
MYSQL_USER="frappe"
MYSQL_PASSWORD="frappe"
FRAPPE_BRANCH="version-15"

# -------------------------------
# HELPER FUNCTIONS
# -------------------------------
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo "❌ $1 not found. Exiting..."
        exit 1
    fi
}
ok() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

# -------------------------------
# 1. SYSTEM UPDATE & DEPENDENCIES
# -------------------------------
echo "---- [1/9] Updating System Packages ----"
sudo apt update -y && sudo apt upgrade -y

echo "---- [2/9] Installing Dependencies ----"
sudo apt install -y python3-dev python3-pip python3-venv python3-testresources \
    build-essential git curl redis-server software-properties-common \
    wkhtmltopdf xvfb libfontconfig libxrender1 libjpeg-dev libx11-dev libxext6 \
    xfonts-75dpi xfonts-base fontconfig mariadb-server mariadb-client \
    libmysqlclient-dev nginx supervisor || fail "Dependency installation failed"

# -------------------------------
# 2. NODE & YARN
# -------------------------------
echo "---- [3/9] Installing NodeJS 18.x & Yarn ----"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g yarn
check_command node
check_command yarn
ok "Node & Yarn installed successfully"

# -------------------------------
# 3. MARIADB CONFIGURATION (From 2nd Script)
# -------------------------------
echo "---- [4/9] Configuring MariaDB ----"
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Run commands as root (no password) - compatible with unix_socket auth
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${MYSQL_USER};
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

sudo bash -c 'cat > /etc/mysql/conf.d/frappe.cnf' <<EOL
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[client]
default-character-set = utf8mb4
EOL

sudo systemctl restart mariadb
ok "MariaDB configured successfully"

# -------------------------------
# 4. CREATE FRAPPE USER
# -------------------------------
echo "---- [5/9] Creating frappe user ----"
if ! id "$FRAPPE_USER" &>/dev/null; then
    sudo adduser --disabled-password --gecos "" $FRAPPE_USER
    sudo usermod -aG sudo $FRAPPE_USER
    ok "User '$FRAPPE_USER' created"
else
    ok "User '$FRAPPE_USER' already exists"
fi

# -------------------------------
# 5. INSTALL BENCH (From 1st Script)
# -------------------------------
echo "---- [6/9] Installing Bench ----"
sudo -H -u $FRAPPE_USER bash << 'EOSU'
set -e
cd ~

pip3 install frappe-bench --break-system-packages

# Initialize Frappe Bench
bench init frappe-bench --frappe-branch version-15
cd frappe-bench

# -------------------------------
# 6. CREATE SITE
# -------------------------------
bench new-site site1.local --mariadb-root-password frappe --admin-password admin

# -------------------------------
# 7. INSTALL APPS (Official + Custom)
# -------------------------------
bench get-app erpnext https://github.com/frappe/erpnext --branch version-15
bench get-app hrms https://github.com/frappe/hrms --branch version-15

# Custom Apps (From 1st Script)
bench get-app custom_hrms https://github.com/mmcytech/custom-hrms.git
bench get-app custom_asset_management https://github.com/mmcytech/custom-asset-management.git
bench get-app custom_it_operations https://github.com/mmcytech/custom-it-operations.git

# -------------------------------
# 8. INSTALL ALL APPS TO SITE
# -------------------------------
bench --site site1.local install-app erpnext
bench --site site1.local install-app hrms
bench --site site1.local install-app custom_hrms
bench --site site1.local install-app custom_asset_management
bench --site site1.local install-app custom_it_operations

bench build
bench restart
EOSU

# -------------------------------
# 9. COMPLETION MESSAGE
# -------------------------------
echo "=================================================================="
echo "✅ ERPNext + HRMS + Custom Apps Installed Successfully!"
echo "Login: http://localhost:8000"
echo "User: Administrator"
echo "Pass: ${ADMIN_PASSWORD}"
echo "=================================================================="
echo "To start the service manually:"
echo "sudo -H -u ${FRAPPE_USER} bash -c 'cd ${BENCH_DIR} && bench start'"
echo "Logs saved at: $LOGFILE"
echo "=================================================================="
