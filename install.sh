#!/bin/bash

# ============================================================================
# MMCY HRMS Complete Installation Script
# This script installs Frappe, creates a bench, sets up a site, and installs
# all required apps (ERPNext, HRMS, and custom apps) in a single run
# ============================================================================

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Configuration Variables - EDIT THESE AS NEEDED
# ============================================================================

# Frappe installer token
FRAPPE_TOKEN="${FRAPPE_TOKEN:-your-token-here}"

# Bench configuration
BENCH_NAME="${BENCH_NAME:-custom-hrms-bench}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"

# Site configuration
SITE_NAME="${SITE_NAME:-hrms.mmcy}"

# MySQL root password (will be prompted if not set)
MYSQL_ROOT_PASSWORD=""

# Apps to install (customize as needed)
APPS_TO_GET=(
    "erpnext:version-15"
    "hrms:version-15"
    "https://github.com/MMCY-Tech/custom-hrms.git:custom-hrms"
    "https://github.com/MMCY-Tech/custom-asset-management.git:custom-asset-management"
    "https://github.com/MMCY-Tech/custom-it-operations.git:custom-it-operations"
)

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# ============================================================================
# Validation Functions
# ============================================================================

check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if running on Linux/macOS
    if [[ ! "$OSTYPE" =~ ^linux || "$OSTYPE" =~ ^darwin ]]; then
        print_error "This script is designed for Linux/macOS systems"
        exit 1
    fi
    
    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        print_error "curl is not installed. Please install curl first."
        exit 1
    fi
    print_success "curl is installed"
    
    # Check if Python 3 is installed
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is not installed. Please install Python 3 first."
        exit 1
    fi
    print_success "Python 3 is installed"
    
    # Check if git is installed
    if ! command -v git &> /dev/null; then
        print_error "Git is not installed. Please install Git first."
        exit 1
    fi
    print_success "Git is installed"
}

get_mysql_password() {
    print_header "MySQL Configuration"
    
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        read -sp "Enter your MySQL root password: " MYSQL_ROOT_PASSWORD
        echo ""
    fi
    
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        print_error "MySQL root password cannot be empty"
        exit 1
    fi
    print_success "MySQL password configured"
}

# ============================================================================
# Installation Functions
# ============================================================================

install_frappe_and_bench() {
    print_header "Installing Frappe Framework and Bench"
    
    if [ "$FRAPPE_TOKEN" == "your-token-here" ]; then
        print_error "Please set FRAPPE_TOKEN environment variable with your actual token"
        print_info "Usage: export FRAPPE_TOKEN='your-actual-token' && bash install-frappe-setup.sh"
        exit 1
    fi
    
    print_info "Running Frappe installer script..."
    curl -fsSL "https://${FRAPPE_TOKEN}@raw.githubusercontent.com/s-yoseph/frappe-installer/main/install.sh" | bash -s -- -t "$FRAPPE_TOKEN"
    
    if [ $? -eq 0 ]; then
        print_success "Frappe and Bench installed successfully"
    else
        print_error "Frappe installation failed"
        exit 1
    fi
}

create_bench() {
    print_header "Creating Bench: $BENCH_NAME"
    
    if [ -d "$BENCH_NAME" ]; then
        print_warning "Bench directory '$BENCH_NAME' already exists"
        read -p "Do you want to use the existing bench? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Removing existing bench..."
            rm -rf "$BENCH_NAME"
            print_info "Creating new bench..."
            bench init --frappe-branch "$FRAPPE_BRANCH" "$BENCH_NAME"
        fi
    else
        print_info "Initializing bench with Frappe branch: $FRAPPE_BRANCH"
        bench init --frappe-branch "$FRAPPE_BRANCH" "$BENCH_NAME"
    fi
    
    if [ $? -eq 0 ]; then
        print_success "Bench created successfully"
    else
        print_error "Bench creation failed"
        exit 1
    fi
}

navigate_to_bench() {
    print_info "Navigating to bench directory: $BENCH_NAME"
    cd "$BENCH_NAME"
}

create_site() {
    print_header "Creating Site: $SITE_NAME"
    
    print_info "MySQL root password will be required..."
    bench new-site "$SITE_NAME" <<< "$MYSQL_ROOT_PASSWORD"
    
    if [ $? -eq 0 ]; then
        print_success "Site created successfully"
    else
        print_error "Site creation failed"
        exit 1
    fi
}

add_site_to_hosts() {
    print_header "Adding Site to Hosts"
    
    print_info "Adding $SITE_NAME to /etc/hosts..."
    bench --site "$SITE_NAME" add-to-hosts
    
    if [ $? -eq 0 ]; then
        print_success "Site added to hosts file"
    else
        print_warning "Could not automatically add to hosts (requires sudo). You may need to add manually."
    fi
}

parse_app_config() {
    local app_config="$1"
    local app_name
    local app_source
    
    if [[ "$app_config" == *":"* ]]; then
        app_name="${app_config##*:}"
        app_source="${app_config%:*}"
    else
        app_name="$app_config"
        app_source="$app_config"
    fi
    
    echo "$app_source|$app_name"
}

get_all_apps() {
    print_header "Installing Apps from Repositories"
    
    for app_config in "${APPS_TO_GET[@]}"; do
        IFS='|' read -r app_source app_name <<< "$(parse_app_config "$app_config")"
        
        print_info "Getting app: $app_name (from: $app_source)..."
        
        if [[ "$app_source" == http* ]]; then
            # Git repository URL
            bench get-app "$app_source"
        else
            # App name (will be fetched from Frappe official repos)
            if [[ "$app_source" == *":"* ]]; then
                # With branch specification
                IFS=':' read -r app_repo app_branch <<< "$app_source"
                bench get-app --branch "$app_branch" "$app_repo"
            else
                # Without branch
                bench get-app "$app_source"
            fi
        fi
        
        if [ $? -eq 0 ]; then
            print_success "App '$app_name' fetched successfully"
        else
            print_error "Failed to fetch app: $app_name"
            exit 1
        fi
    done
}

install_all_apps() {
    print_header "Installing Apps on Site: $SITE_NAME"
    
    for app_config in "${APPS_TO_GET[@]}"; do
        IFS='|' read -r app_source app_name <<< "$(parse_app_config "$app_config")"
        
        print_info "Installing app: $app_name..."
        bench --site "$SITE_NAME" install-app "$app_name"
        
        if [ $? -eq 0 ]; then
            print_success "App '$app_name' installed successfully"
        else
            print_error "Failed to install app: $app_name"
            exit 1
        fi
    done
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header "MMCY HRMS Complete Installation"
    
    print_info "Configuration:"
    echo "  Bench Name: $BENCH_NAME"
    echo "  Frappe Branch: $FRAPPE_BRANCH"
    echo "  Site Name: $SITE_NAME"
    echo "  Total Apps to Install: ${#APPS_TO_GET[@]}"
    echo ""
    
    read -p "Continue with installation? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Installation cancelled"
        exit 0
    fi
    
    # Step 1: Check prerequisites
    check_prerequisites
    
    # Step 2: Get MySQL password
    get_mysql_password
    
    # Step 3: Install Frappe and Bench
    install_frappe_and_bench
    
    # Step 4: Create bench
    create_bench
    navigate_to_bench
    
    # Step 5: Create site
    create_site
    
    # Step 6: Add site to hosts
    add_site_to_hosts
    
    # Step 7: Get all apps
    get_all_apps
    
    # Step 8: Install all apps on the site
    install_all_apps
    
    # Final success message
    print_header "Installation Complete!"
    print_success "All components have been installed successfully!"
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo "  1. Start the Frappe development server:"
    echo "     ${BLUE}bench start${NC}"
    echo ""
    echo "  2. Access your site in browser:"
    echo "     ${BLUE}http://$SITE_NAME:8000${NC}"
    echo ""
    echo "  3. If you need to add more custom apps later:"
    echo "     ${BLUE}bench get-app <repo-url>${NC}"
    echo "     ${BLUE}bench --site $SITE_NAME install-app <app-name>${NC}"
    echo ""
}

# Run main function
main
