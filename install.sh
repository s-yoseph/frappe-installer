#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

BENCH_DIR="/home/selam/frappe-setup/frappe-bench"
DB_PORT=3307
SITE_NAME="mmcy.hrms"
ADMIN_PASS="admin"


# Function to verify app exists
verify_app() {
    local app=$1
    if [ -d "$BENCH_DIR/apps/$app" ]; then
        echo -e "${GREEN}✓ App '$app' verified${NC}"
        return 0
    else
        echo -e "${RED}✗ App '$app' NOT found in apps directory${NC}"
        return 1
    fi
}


echo "========================================="
echo "Fetching apps..."
echo "========================================="

APPS_TO_INSTALL=("erpnext" "hrms" "custom-hrms" "custom-asset-management" "custom-it-operations")

for app in "${APPS_TO_INSTALL[@]}"; do
    echo ""
    echo "Fetching $app..."
    
    if [ "$app" = "erpnext" ]; then
        if ! bench get-app --branch version-15 "https://github.com/frappe/erpnext.git"; then
            echo -e "${RED}Failed to fetch $app${NC}"
            exit 1
        fi
    elif [ "$app" = "hrms" ]; then
        if ! bench get-app --branch version-15 "https://github.com/frappe/hrms.git"; then
            echo -e "${RED}Failed to fetch $app${NC}"
            exit 1
        fi
    elif [ "$app" = "custom-hrms" ]; then
        if ! bench get-app --branch main "https://github.com/MMCY-Tech/custom-hrms.git"; then
            echo -e "${YELLOW}Warning: Failed to fetch custom-hrms, continuing...${NC}"
        fi
    elif [ "$app" = "custom-asset-management" ]; then
        if ! bench get-app --branch main "https://github.com/MMCY-Tech/custom-asset-management.git"; then
            echo -e "${YELLOW}Warning: Failed to fetch custom-asset-management, continuing...${NC}"
        fi
    elif [ "$app" = "custom-it-operations" ]; then
        if ! bench get-app --branch main "https://github.com/MMCY-Tech/custom-it-operations.git"; then
            echo -e "${YELLOW}Warning: Failed to fetch custom-it-operations, continuing...${NC}"
        fi
    fi
    
    sleep 2
done

echo ""
echo "========================================="
echo "Verifying apps were fetched..."
echo "========================================="

for app in "frappe" "erpnext" "hrms"; do
    if ! verify_app "$app"; then
        echo -e "${RED}ERROR: Core app '$app' is missing!${NC}"
        exit 1
    fi
done

# Verify custom apps (warnings if missing)
for app in "custom-hrms" "custom-asset-management" "custom-it-operations"; do
    if ! verify_app "$app"; then
        echo -e "${YELLOW}WARNING: Custom app '$app' is missing (will skip installation)${NC}"
    fi
done

echo ""
echo "========================================="
echo "Creating site..."
echo "========================================="

# Remove old site if it exists
if [ -d "$BENCH_DIR/sites/$SITE_NAME" ]; then
    echo "Removing old site..."
    sudo rm -rf "$BENCH_DIR/sites/$SITE_NAME" || true
fi

sleep 5

# Create new site with core apps
bench new-site $SITE_NAME --db-type mariadb --admin-password=$ADMIN_PASS

echo ""
echo "========================================="
echo "Installing apps on site..."
echo "========================================="

INSTALL_APPS=("erpnext" "hrms")

for app in "${INSTALL_APPS[@]}"; do
    echo ""
    echo "Installing $app..."
    if ! bench install-app $app --site=$SITE_NAME; then
        echo -e "${RED}Failed to install $app${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ $app installed${NC}"
done

# Install custom apps if they exist
for app in "custom-hrms" "custom-asset-management" "custom-it-operations"; do
    if [ -d "$BENCH_DIR/apps/$app" ]; then
        echo ""
        echo "Installing $app..."
        
        # Backup fixtures for custom apps
        if [ "$app" = "custom-hrms" ]; then
            FIXTURE_PATH="$BENCH_DIR/apps/custom-hrms/custom_hrms/fixtures"
            if [ -d "$FIXTURE_PATH" ]; then
                mv "$FIXTURE_PATH" "$FIXTURE_PATH.backup"
            fi
        elif [ "$app" = "custom-asset-management" ]; then
            FIXTURE_PATH="$BENCH_DIR/apps/custom-asset-management/custom_asset_management/fixtures"
            if [ -d "$FIXTURE_PATH" ]; then
                mv "$FIXTURE_PATH" "$FIXTURE_PATH.backup"
            fi
        fi
        
        if ! bench install-app $app --site=$SITE_NAME; then
            echo -e "${RED}Failed to install $app${NC}"
        else
            echo -e "${GREEN}✓ $app installed${NC}"
        fi
    fi
done

echo ""
echo "========================================="
echo "Running migrations..."
echo "========================================="

bench migrate --site=$SITE_NAME

echo ""
echo "========================================="
echo "Building assets..."
echo "========================================="

bench build

echo ""
echo "========================================="
echo "Clearing cache..."
echo "========================================="

bench clear-cache --site=$SITE_NAME
bench clear-website-cache --site=$SITE_NAME

# Update hosts file
if ! grep -q "mmcy.hrms" /etc/hosts; then
    echo "127.0.0.1 mmcy.hrms" | sudo tee -a /etc/hosts > /dev/null
fi

# Update Procfile
echo "web: bench serve --host 0.0.0.0 --port 8000" > Procfile

echo ""
echo "========================================="
echo "✓ Installation Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Navigate to bench: cd $BENCH_DIR"
echo "2. Start the server: bench start"
echo "3. Access at: http://localhost:8000"
echo ""
echo "Login credentials:"
echo "Site: $SITE_NAME"
echo "Admin Password: $ADMIN_PASS"
echo ""
echo "Installed apps:"
bench list-apps
