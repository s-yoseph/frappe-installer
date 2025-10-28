#!/bin/bash

# MariaDB Setup for Frappe
set -e

echo "Preparing MariaDB environment..."

# Stop any existing services
echo "Stopping any existing MariaDB/MySQL services..."
sudo systemctl stop mariadb mysql 2>/dev/null || true
sleep 2

# Kill any lingering processes
echo "Killing processes on port 3306 and 3307..."
sudo fuser -k 3306/tcp 2>/dev/null || true
sudo fuser -k 3307/tcp 2>/dev/null || true
sleep 1

# Clean up socket and lock files
echo "Cleaning up socket and lock files..."
sudo rm -f /run/mysqld/mysqld.sock
sudo rm -f /tmp/mysql_3307.sock
sudo rm -f /var/run/mysqld/mysqld.sock
sudo rm -f /var/lib/mysql/mysqld.pid

# Create necessary directories with proper permissions
echo "Creating log and run directories..."
sudo mkdir -p /var/log/mysql
sudo mkdir -p /var/run/mysqld
sudo chown -R mysql:mysql /var/log/mysql
sudo chown -R mysql:mysql /var/run/mysqld
sudo chmod 755 /var/log/mysql
sudo chmod 755 /var/run/mysqld

# Create empty log files
sudo touch /var/log/mysql/error.log
sudo touch /var/log/mysql/slow.log
sudo chown mysql:mysql /var/log/mysql/error.log
sudo chown mysql:mysql /var/log/mysql/slow.log
sudo chmod 644 /var/log/mysql/error.log
sudo chmod 644 /var/log/mysql/slow.log

# Initialize MariaDB if needed
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB system tables (first time)..."
    sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql --skip-test-db 2>&1 || true
fi

# Write MariaDB configuration for port 3307
echo "Writing MariaDB configuration for port 3307..."
sudo tee /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
# Basic Settings
user = mysql
pid-file = /var/run/mysqld/mysqld.pid
socket = /run/mysqld/mysqld.sock
port = 3307
basedir = /usr
datadir = /var/lib/mysql
tmpdir = /tmp
lc-messages-dir = /usr/share/mysql
skip-external-locking

# Logging
log_error = /var/log/mysql/error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# InnoDB
default-storage-engine = InnoDB
innodb_buffer_pool_size = 256M
innodb_log_file_size = 100M

# Bind Address
bind-address = 127.0.0.1

# Character Set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysqldump]
quick
quote-names
max_allowed_packet = 16M

[mysql]
# no-auto-rehash

[isamchk]
key_buffer_size = 16M
EOF

# Reload systemd daemon
echo "Reloading systemd configuration..."
sudo systemctl daemon-reload

# Enable and start MariaDB service
echo "Enabling and starting MariaDB service..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Wait for MariaDB to be ready with improved check
echo "Waiting for MariaDB to accept connections..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if sudo mysql -u root --socket=/run/mysqld/mysqld.sock -e "SELECT 1" &>/dev/null; then
        echo "MariaDB is ready!"
        break
    fi
    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "WARNING: MariaDB startup check timed out, but service may still be running"
    echo "Checking service status..."
    sudo systemctl status mariadb
fi

# Verify connection
echo "Verifying MariaDB connection..."
if sudo mysql -u root --socket=/run/mysqld/mysqld.sock -e "SELECT VERSION();" 2>/dev/null; then
    echo "✓ MariaDB is running successfully on port 3307"
else
    echo "✗ Failed to connect to MariaDB"
    exit 1
fi

echo "MariaDB setup completed successfully!"
