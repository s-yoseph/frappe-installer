#!/bin/bash

# Frappe/ERPNext Complete Installation Script
# Installs all dependencies, Frappe, ERPNext, HRMS, and custom apps
# No validation checks - just install everything

set -e

echo "=========================================="
echo "Frappe/ERPNext Complete Installation"
echo "=========================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SITE_NAME="mmcy.hrms"
FRAPPE_USER="frappe"
BENCH_DIR="/home/frappe/frappe-bench"

# Step 1: Update system packages
echo -e "${YELLOW}Step 1: Updating system packages...${NC}"
sudo apt-get update
sudo apt-get upgrade -y

# Step 2: Install system dependencies
echo -e "${YELLOW}Step 2: Installing system dependencies...${NC}"
sudo apt-get install -y \
    python3-dev \
    python3-pip \
    python3-venv \
    git \
    curl \
    wget \
    build-essential \
    libssl-dev \
    libffi-dev \
    libpq-dev \
    libjpeg-dev \
    zlib1g-dev \
    xvfb \
    libfontconfig \
    wkhtmltopdf

# Step 3: Install MariaDB
echo -e "${YELLOW}Step 3: Installing MariaDB...${NC}"
sudo apt-get install -y mariadb-server mariadb-client
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Configure MariaDB for Frappe
sudo mysql -e "SET GLOBAL character_set_server = 'utf8mb4';"
sudo mysql -e "SET GLOBAL collation_server = 'utf8mb4_unicode_ci';"

# Step 4: Install Redis
echo -e "${YELLOW}Step 4: Installing Redis...${NC}"
sudo apt-get install -y redis-server
sudo systemctl start redis-server
sudo systemctl enable redis-server

# Step 5: Install Node.js and npm
echo -e "${YELLOW}Step 5: Installing Node.js and npm...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Step 6: Install Frappe Bench
echo -e "${YELLOW}Step 6: Installing Frappe Bench...${NC}"
sudo -u $FRAPPE_USER pip3 install --upgrade pip
sudo -u $FRAPPE_USER pip3 install frappe-bench

# Step 7: Create Frappe Bench
echo -e "${YELLOW}Step 7: Creating Frappe Bench...${NC}"
if [ ! -d "$BENCH_DIR" ]; then
    sudo -u $FRAPPE_USER bench init $BENCH_DIR --frappe-branch version-15
    cd $BENCH_DIR
else
    echo "Bench directory already exists at $BENCH_DIR"
    cd $BENCH_DIR
fi

# Step 8: Create new site
echo -e "${YELLOW}Step 8: Creating new site: $SITE_NAME...${NC}"
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench new-site $SITE_NAME --admin-password=admin --mariadb-root-password=root

# Step 9: Clone and install Frappe apps
echo -e "${YELLOW}Step 9: Cloning and installing apps...${NC}"

# Install ERPNext
echo "Installing ERPNext..."
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench get-app erpnext https://github.com/frappe/erpnext.git
sudo -u $FRAPPE_USER bench --site $SITE_NAME install-app erpnext

# Install HRMS
echo "Installing HRMS..."
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench get-app hrms https://github.com/frappe/hrms.git
sudo -u $FRAPPE_USER bench --site $SITE_NAME install-app hrms

# Install custom apps (update paths as needed)
echo "Installing custom-hrms..."
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench get-app custom-hrms /path/to/custom-hrms
sudo -u $FRAPPE_USER bench --site $SITE_NAME install-app custom-hrms

echo "Installing custom-asset-management..."
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench get-app custom-asset-management /path/to/custom-asset-management
sudo -u $FRAPPE_USER bench --site $SITE_NAME install-app custom-asset-management

echo "Installing custom-it-operations..."
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench get-app custom-it-operations /path/to/custom-it-operations
sudo -u $FRAPPE_USER bench --site $SITE_NAME install-app custom-it-operations

# Step 10: Start Frappe
echo -e "${YELLOW}Step 10: Starting Frappe...${NC}"
cd $BENCH_DIR
sudo -u $FRAPPE_USER bench start

echo -e "${GREEN}=========================================="
echo "Installation Complete!"
echo "=========================================="
echo "Access Frappe at: http://localhost:8000"
echo "Site: $SITE_NAME"
echo "Username: Administrator"
echo "Password: admin"
echo -e "${NC}"
