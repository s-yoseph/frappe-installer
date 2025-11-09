# Frappe Installer

This repository provides a **one-command installer script (`install.sh`)** for setting up:

- **Frappe v15**
- **ERPNext**
- **HRMS**
- **MMCY custom apps**:
  - `mmcy_hrms`
  - `mmcy_asset_management`
  - `mmcy_it_operations`

The script handles dependencies, MariaDB setup, and fixture workarounds (e.g., `fixed_asset_account`) for a smooth installation.

---

## Prerequisites

- **Ubuntu 22.04** or **WSL (Windows Subsystem for Linux)**  
- **GitHub Personal Access Token (PAT)** with `repo` scope for private repositories:  
  - [`s-yoseph/frappe-installer`](https://github.com/s-yoseph/frappe-installer)  
  - `MMCY-Tech/*`  

👉 Generate your PAT here: [github.com/settings/tokens](https://github.com/settings/tokens)  

- Access to this private repository and MMCY-Tech repos (contact the owner for access).

---

## Installation

1. Open a terminal in a **fresh directory** to avoid conflicts:
   ```bash
   mkdir ~/test-frappe && cd ~/test-frappe

2. Run the installer with your PAT:
      ```bash
    curl -fsSL https://<your_pat>@raw.githubusercontent.com/s-yoseph/frappe-installer/main/install.sh | bash -s -- -t <your_pat>

Replace <your_pat> with your GitHub PAT.
This downloads and executes install.sh, installing all apps (~5–15 minutes).

3. Start the Frappe server:
   ```bash
   cd ~/frappe-setup/frappe-bench
   bench start

## Post-Installation

Verify installed apps:



 
 # Kill current processes
pkill -f "bench start"
pkill -f redis
# Clear any locks
rm -f /tmp/*.sock
# Start fresh
bench start
 
 
bench --site "$SITE_NAME" install-app mmcy_hrms
bench --site "$SITE_NAME" install-app mmcy_asset_management
bench --site "$SITE_NAME" install-app mmcy_it_operations

 
