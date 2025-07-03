#!/bin/bash

# Color output for better readability
GREEN="\033[0;32m"
RED="\033[0;31m"
RESET="\033[0m"

# Function to print messages
print_message() {
    echo -e "${GREEN}$1${RESET}"
}

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root!${RESET}"
    exit 1
fi

# Update system
update_system() {
    print_message "Updating the system..."
    apt update && apt upgrade -y
    print_message "System updated."
}

# Create a new user
create_user() {
    read -p "Enter the username to create: " username
    adduser $username
    usermod -aG sudo $username
    print_message "User $username created and added to the sudo group."
}

# Configure SSH
configure_ssh() {
    print_message "Configuring SSH..."
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl reload sshd
    print_message "SSH configuration updated. Root login disabled and password authentication disabled."
}

# Setup UFW firewall
setup_firewall() {
    print_message "Setting up UFW firewall..."
    apt install ufw -y
    ufw allow OpenSSH
    ufw enable
    print_message "Firewall configured. Only SSH is allowed."
}

# Install Fail2Ban
install_fail2ban() {
    print_message "Installing Fail2Ban..."
    apt install fail2ban -y
    systemctl enable fail2ban
    systemctl start fail2ban
    print_message "Fail2Ban installed and running."
}

# Disable unused network services
disable_services() {
    print_message "Disabling unused services..."
    systemctl stop cups
    systemctl disable cups
    print_message "Common unused services disabled."
}

# Secure shared memory
secure_shared_memory() {
    print_message "Securing shared memory..."
    echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    mount -o remount /dev/shm
    print_message "Shared memory secured."
}

# Configure automatic updates
configure_auto_updates() {
    print_message "Configuring automatic updates..."
    apt install unattended-upgrades -y
    dpkg-reconfigure -plow unattended-upgrades
    print_message "Automatic updates configured."
}

# Main menu
while true; do
    echo "Choose a task to perform:"
    echo "1. Update the system"
    echo "2. Create a new user"
    echo "3. Configure SSH"
    echo "4. Setup UFW firewall"
    echo "5. Install Fail2Ban"
    echo "6. Disable unused network services"
    echo "7. Secure shared memory"
    echo "8. Configure automatic updates"
    echo "9. Exit"
    read -p "Enter your choice [1-9]: " choice

    case $choice in
        1) update_system ;;
        2) create_user ;;
        3) configure_ssh ;;
        4) setup_firewall ;;
        5) install_fail2ban ;;
        6) disable_services ;;
        7) secure_shared_memory ;;
        8) configure_auto_updates ;;
        9) print_message "Exiting the script. Stay secure!"; exit ;;
        *) echo -e "${RED}Invalid choice!${RESET}" ;;
    esac
done