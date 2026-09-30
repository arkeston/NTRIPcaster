#!/bin/bash
#
# NTRIP Caster One-click uninstall script
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
  echo -e "${RED}Error: Please use root Permission to run this script (sudo ./uninstall.sh)${NC}"
  exit 1
fi

# Show welcome message
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}       2RTK NTRIP Caster One-click uninstall script         ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo -e "${RED}Warning: This script will be completely uninstalled 2RTK NTRIP Caster and all its data${NC}"
echo ""

# Confirm uninstallation
read -p "Are you sure you want to uninstall 2RTK NTRIP Caster ?? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo -e "${GREEN}Uninstall canceled${NC}"
  exit 0
fi

# Set the installation directory (same as in the installation script)
INSTALL_DIR="/opt/2rtk"
CONFIG_DIR="/etc/2rtk"
LOG_DIR="/var/log/2rtk"
SERVICE_NAME="2rtk"

# Stopping and disabling the service
echo -e "${YELLOW}Stopping and disabling the service...${NC}"
systemctl stop $SERVICE_NAME
systemctl disable $SERVICE_NAME
systemctl daemon-reload

# Delete systemd Service Files
echo -e "${YELLOW}Delete systemd Service Files...${NC}"
rm -f /etc/systemd/system/$SERVICE_NAME.service

# Delete Nginx Configuration
echo -e "${YELLOW}Delete Nginx Configuration...${NC}"
rm -f /etc/nginx/sites-enabled/2rtk
rm -f /etc/nginx/sites-available/2rtk
systemctl restart nginx

# Delete Log Rotation Configuration
echo -e "${YELLOW}Delete Log Rotation Configuration...${NC}"
rm -f /etc/logrotate.d/2rtk

# Delete firewall rules (if they exist)
echo -e "${YELLOW}Delete firewall rule...${NC}"
if command -v ufw > /dev/null; then
    ufw delete allow 2101/tcp
    ufw delete allow 5757/tcp
    echo -e "${GREEN}deleted UFW Firewall rules${NC}"
elif command -v firewall-cmd > /dev/null; then
    firewall-cmd --permanent --remove-port=2101/tcp
    firewall-cmd --permanent --remove-port=5757/tcp
    firewall-cmd --reload
    echo -e "${GREEN}deleted firewalld Firewall rules${NC}"
else
    echo -e "${YELLOW}No supported firewall detected, please delete firewall rules manually${NC}"
fi

# Backup data (optional)
echo -e "${YELLOW}Whether data needs to be backed up? (y/n): ${NC}"
read backup_choice
if [[ "$backup_choice" == "y" || "$backup_choice" == "Y" ]]; then
    BACKUP_DIR="/root/2rtk_backup_$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Create backup directory: $BACKUP_DIR${NC}"
    mkdir -p $BACKUP_DIR
    
    # Backup profile
    if [ -d "$CONFIG_DIR" ]; then
        cp -r $CONFIG_DIR $BACKUP_DIR/
        echo -e "${GREEN}Profile backed up to $BACKUP_DIR/$(basename $CONFIG_DIR)${NC}"
    fi
    
    # Backing up the database
    if [ -f "$INSTALL_DIR/2rtk.db" ]; then
        cp $INSTALL_DIR/2rtk.db $BACKUP_DIR/
        echo -e "${GREEN}Database backed up to $BACKUP_DIR/2rtk.db${NC}"
    fi
    
    # Backup logs
    if [ -d "$LOG_DIR" ]; then
        cp -r $LOG_DIR $BACKUP_DIR/
        echo -e "${GREEN}Log files backed up to $BACKUP_DIR/$(basename $LOG_DIR)${NC}"
    fi
    
    echo -e "${GREEN}Data backup completed: $BACKUP_DIR${NC}"
fi

# Delete the installation directory
echo -e "${YELLOW}Delete the installation directory...${NC}"
rm -rf $INSTALL_DIR

# Delete configuration directory
echo -e "${YELLOW}Delete configuration directory...${NC}"
rm -rf $CONFIG_DIR

# Delete log directory
echo -e "${YELLOW}Delete log directory...${NC}"
rm -rf $LOG_DIR

# Ask to uninstall dependency packages
echo -e "${YELLOW}Whether to uninstall installed dependencies? (y/n): ${NC}"
read deps_choice
if [[ "$deps_choice" == "y" || "$deps_choice" == "Y" ]]; then
    echo -e "${YELLOW}Uninstall dependency packages...${NC}"
    # Note: Only packages explicitly installed in the installation script are uninstalled here, excluding their dependencies
    apt-get remove -y supervisor nginx
    echo -e "${GREEN}Dependency package uninstalled${NC}"
else
    echo -e "${YELLOW}Keep dependency packages${NC}"
fi

# Show uninstall completion information
echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}2RTK NTRIP Caster Uninstallation complete!${NC}"
echo -e "${BLUE}------------------------------------------------${NC}"
echo -e "${YELLOW}The following has been removed:${NC}"
echo -e "  - Service Files: /etc/systemd/system/$SERVICE_NAME.service"
echo -e "  - Installation directory: $INSTALL_DIR"
echo -e "  - Configuration directory: $CONFIG_DIR"
echo -e "  - Log directory: $LOG_DIR"
echo -e "  - Nginx Configuration: /etc/nginx/sites-available/2rtk"
echo -e "  - Log rotation configuration: /etc/logrotate.d/2rtk"

if [[ "$backup_choice" == "y" || "$backup_choice" == "Y" ]]; then
    echo -e "${BLUE}------------------------------------------------${NC}"
    echo -e "${GREEN}Data backed up to: $BACKUP_DIR${NC}"
fi

echo -e "${BLUE}=================================================${NC}"

exit 0