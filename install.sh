#!/bin/bash
#
# NTRIP Caster One-click installation script
# Applies to Debian/Ubuntu System
# Author: 2RTK
# Version: 1.0.0
#

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if the root Permission to run
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please use root Permission to run this script (sudo ./install.sh)${NC}"
  exit 1
fi

# Show welcome message
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}       2RTK NTRIP Caster One-click installation script         ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}This script will be installed automatically 2RTK NTRIP Caster and its dependencies, and set power-on autostart${NC}"
echo ""

# Check system type
if [ -f /etc/debian_version ]; then
    echo -e "${GREEN}Detected Debian/Ubuntu System, continue installation...${NC}"
else
    echo -e "${RED}Error: This script only supports Debian/Ubuntu System${NC}"
    exit 1
fi

# Set the installation directory
INSTALL_DIR="/opt/2rtk"
CONFIG_DIR="/etc/2rtk"
LOG_DIR="/var/log/2rtk"
SERVICE_NAME="2rtk"

# Create installation directory
echo -e "${YELLOW}Create installation directory...${NC}"
mkdir -p $INSTALL_DIR
mkdir -p $CONFIG_DIR
mkdir -p $LOG_DIR

# Create log subdirectory
echo -e "${YELLOW}Create log directory...${NC}"


# Updating the system and installing dependencies
echo -e "${YELLOW}Updating the system and installing dependencies...${NC}"
apt-get update
apt-get install -y python3 python3-pip python3-venv supervisor nginx git

# Create Python Virtual environment
echo -e "${YELLOW}Create Python Virtual environment...${NC}"
python3 -m venv $INSTALL_DIR/venv
source $INSTALL_DIR/venv/bin/activate

# Download the project file
echo -e "${YELLOW}Download the project file...${NC}"
cd /tmp
git clone https://github.com/Rampump/NTRIPcaster.git
cp -r NTRIPcaster/* $INSTALL_DIR/

# Copy and configure config.ini
echo -e "${YELLOW}Configuration config.ini...${NC}"
if [ -f $INSTALL_DIR/config.ini.example ]; then
    # Backup the original configuration file
    cp $INSTALL_DIR/config.ini.example $CONFIG_DIR/config.ini.original
    
    # Copy and modify the configuration file
    cp $INSTALL_DIR/config.ini.example $CONFIG_DIR/config.ini
    
    # Update path in profile
    sed -i "s|path = /app/data/2rtk.db|path = $INSTALL_DIR/data/2rtk.db|g" $CONFIG_DIR/config.ini
    sed -i "s|main_log = /app/logs/main.log|main_log = $LOG_DIR/main.log|g" $CONFIG_DIR/config.ini
    sed -i "s|ntrip_log = /app/logs/ntrip.log|ntrip_log = $LOG_DIR/ntrip.log|g" $CONFIG_DIR/config.ini
    sed -i "s|error_log = /app/logs/errors.log|error_log = $LOG_DIR/errors.log|g" $CONFIG_DIR/config.ini
    
    # Set up production environment configuration
    sed -i "s|debug = true|debug = false|g" $CONFIG_DIR/config.ini
    
    # Generate a random key
    RANDOM_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    sed -i "s|secret_key = your-secret-key-change-this-in-production|secret_key = $RANDOM_KEY|g" $CONFIG_DIR/config.ini
    
    echo -e "${GREEN}Profile updated${NC}"
else
    echo -e "${RED}Error: not found config.ini.example Files${NC}"
    exit 1
fi

# Installation Python Dependencies
echo -e "${YELLOW}Installation Python Dependencies...${NC}"
$INSTALL_DIR/venv/bin/pip install --upgrade pip
$INSTALL_DIR/venv/bin/pip install -r $INSTALL_DIR/requirements.txt

# Create systemd Service Files
echo -e "${YELLOW}Create systemd Service Files...${NC}"
cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=NTRIP Caster Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/venv/bin"
Environment="NTRIP_CONFIG_FILE=$CONFIG_DIR/config.ini"
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/main.py
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/main.log
StandardError=append:$LOG_DIR/errors.log

[Install]
WantedBy=multi-user.target
EOF

# Create log rollover configuration
echo -e "${YELLOW}Create log rollover configuration...${NC}"
cat > /etc/logrotate.d/2rtk << EOF
$LOG_DIR/main.log $LOG_DIR/ntrip.log $LOG_DIR/errors.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload 2rtk.service > /dev/null 2>&1 || true
    endscript
}
EOF

# Set file permissions
echo -e "${YELLOW}Set file permissions...${NC}"
chmod +x $INSTALL_DIR/main.py
chown -R root:root $INSTALL_DIR
chown -R root:root $CONFIG_DIR
chown -R root:root $LOG_DIR

# Set log directory permissions
echo -e "${YELLOW}Set log directory permissions...${NC}"
chmod -R 755 $LOG_DIR
find $LOG_DIR -type d -exec chmod 755 {} \;
find $LOG_DIR -type f -exec chmod 644 {} \;

# Create a database directory
echo -e "${YELLOW}Create a database directory...${NC}"
mkdir -p $INSTALL_DIR/data
chmod 755 $INSTALL_DIR/data

# Create symbolic links for easy access to profiles
ln -sf $CONFIG_DIR/config.ini $INSTALL_DIR/config.ini

# Enable and start the service
echo -e "${YELLOW}Enable and start the service...${NC}"
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

# Configure firewall (if present)
echo -e "${YELLOW}Configure firewall...${NC}"
if command -v ufw > /dev/null; then
    ufw allow 2101/tcp  # NTRIP Port
    ufw allow 5757/tcp  # Web Admin interface ports
    echo -e "${GREEN}Configured UFW Firewall rules${NC}"
elif command -v firewall-cmd > /dev/null; then
    firewall-cmd --permanent --add-port=2101/tcp
    firewall-cmd --permanent --add-port=5757/tcp
    firewall-cmd --reload
    echo -e "${GREEN}Configured firewalld Firewall rules${NC}"
else
    echo -e "${YELLOW}No supported firewall detected, please configure firewall rules manually${NC}"
fi

# Create Nginx Configuration (optional, for reverse proxy Web Admin Interface)
echo -e "${YELLOW}Create Nginx Configuration...${NC}"
cat > /etc/nginx/sites-available/2rtk << EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5757;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# Enable Nginx Configuration
ln -sf /etc/nginx/sites-available/2rtk /etc/nginx/sites-enabled/
systemctl restart nginx

# Check service status
echo -e "${YELLOW}Check service status...${NC}"
sleep 3
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}NTRIP Caster Service started successfully!${NC}"
else
    echo -e "${RED}NTRIP Caster Service start failed, please check the log: $LOG_DIR/errors.log${NC}"
fi

# Show installation information
echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}2RTK NTRIP Caster Installation complete!${NC}"
echo -e "${BLUE}------------------------------------------------${NC}"
echo -e "${YELLOW}Installation directory:${NC} $INSTALL_DIR"
echo -e "${YELLOW}Configuration directory:${NC} $CONFIG_DIR"
echo -e "${YELLOW}Log directory:${NC} $LOG_DIR"
echo -e "${YELLOW}NTRIP Port:${NC} 2101"
echo -e "${YELLOW}Web Admin Interface:${NC} http://ServerIP:5757"
echo -e "${YELLOW}Nginx Proxy:${NC} http://ServerIP"
echo -e "${BLUE}------------------------------------------------${NC}"
echo -e "${YELLOW}Service Management Commands:${NC}"
echo -e "  Start the service: ${GREEN}systemctl start $SERVICE_NAME${NC}"
echo -e "  Stop the service: ${GREEN}systemctl stop $SERVICE_NAME${NC}"
echo -e "  Restart the service: ${GREEN}systemctl restart $SERVICE_NAME${NC}"
echo -e "  Check status: ${GREEN}systemctl status $SERVICE_NAME${NC}"
echo -e "  View Log: ${GREEN}journalctl -u $SERVICE_NAME${NC}"
echo -e "${BLUE}=================================================${NC}"

# Prompt to change default password
echo -e "${RED}Safety Tips: Please change the default admin password as soon as possible!${NC}"
echo -e "Default admin account: admin"
echo -e "Default Admin Password: admin123"

exit 0