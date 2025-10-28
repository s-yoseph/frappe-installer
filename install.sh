#!/bin/bash

# MariaDB Setup - CORRECTED VERSION
DB_PORT=3307
MYSQL_SOCKET="/tmp/mysql_${DB_PORT}.sock"
MYSQL_DATA_DIR="/var/lib/mysql_${DB_PORT}"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Preparing MariaDB environment..."

# 1. STOP existing MariaDB/MySQL services completely
echo "Stopping any existing MariaDB/MySQL services..."
sudo systemctl stop mariadb.service 2>/dev/null || true
sudo systemctl stop mysql.service 2>/dev/null || true
sleep 2

# 2. KILL any lingering processes on both ports
echo "Killing processes on port 3306 and 3307..."
sudo fuser -k 3306/tcp 2>/dev/null || true
sudo fuser -k 3307/tcp 2>/dev/null || true
sleep 2

# 3. CLEAN UP all socket, PID, and lock files
echo "Cleaning up socket and lock files..."
sudo rm -f /var/run/mysqld/mysqld.sock
sudo rm -f /var/run/mysqld/mysqld.pid
sudo rm -f /var/run/mysqld/mysqld.lock
sudo rm -f "$MYSQL_SOCKET"
sudo rm -f /var/lib/mysql/mysql.sock
sudo rm -f /var/lib/mysql/mysqld.sock

# 4. MODIFY the MAIN MariaDB config file directly
echo "Configuring MariaDB to use port $DB_PORT..."
sudo tee /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
# Port configuration
port = $DB_PORT
bind-address = 127.0.0.1
socket = $MYSQL_SOCKET

# InnoDB settings
default-storage-engine = InnoDB
innodb_buffer_pool_size = 256M
innodb_log_file_size = 100M

# Performance settings
max_connections = 500
max_allowed_packet = 256M
thread_stack = 192K
thread_cache_size = 8
myisam_recover_options = BACKUP

# Logging
log_error = /var/log/mysql/error.log
log_queries_not_using_indexes = 1
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# Skip external locking
skip-external-locking

[mysqldump]
quick
quote-names
max_allowed_packet = 16M

[mysql]
socket = $MYSQL_SOCKET

[mysqld_safe]
socket = $MYSQL_SOCKET
log_error = /var/log/mysql/error.log
pid-file = /var/run/mysqld/mysqld.pid
EOF

# 5. Ensure proper permissions
echo "Setting permissions..."
sudo chown mysql:mysql /etc/mysql/my.cnf
sudo chmod 644 /etc/mysql/my.cnf

# 6. Create data directory if needed
if [ ! -d "$MYSQL_DATA_DIR" ]; then
    echo "Creating MariaDB data directory..."
    sudo mkdir -p "$MYSQL_DATA_DIR"
    sudo chown mysql:mysql "$MYSQL_DATA_DIR"
    sudo chmod 700 "$MYSQL_DATA_DIR"
fi

# 7. Initialize MariaDB if needed
if [ ! -f "$MYSQL_DATA_DIR/ibdata1" ]; then
    echo "Initializing MariaDB system tables (first time)..."
    sudo mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" --socket="$MYSQL_SOCKET" 2>&1 | grep -v "Warning"
fi

# 8. START MariaDB service
echo "Enabling and starting MariaDB service..."
sudo systemctl daemon-reload
sudo systemctl enable mariadb.service
sudo systemctl start mariadb.service

# 9. VERIFY it started correctly
sleep 3
if sudo systemctl is-active --quiet mariadb.service; then
    echo "MariaDB started successfully on port $DB_PORT"
    
    # Test connection
    if sudo mysql --socket="$MYSQL_SOCKET" -u root -e "SELECT 1" > /dev/null 2>&1; then
        echo "MariaDB connection test: SUCCESS"
    else
        echo "WARNING: MariaDB is running but connection test failed"
        sudo journalctl -xeu mariadb.service | tail -20
    fi
else
    echo "ERROR: Failed to start MariaDB. Checking logs..."
    sudo journalctl -xeu mariadb.service | tail -30
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - MariaDB setup completed successfully!"
