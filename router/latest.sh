#!/bin/bash

# Source the configuration file
source ./router-config.conf

# Update and install required packages
sudo apt update
sudo apt install -y iptables-persistent network-manager

# Ensure NetworkManager is enabled and running
sudo systemctl enable NetworkManager
sudo systemctl start NetworkManager

# Delete existing connections and configurations
sudo nmcli connection delete "$SSID" || true
sudo nmcli connection delete eth0 || true
sudo nmcli connection delete wlan0 || true
sudo nmcli connection delete eth1 || true

# Ensure NetworkManager manages wlan0 and eth1
sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf <<EOF
[keyfile]
unmanaged-devices=none
EOF

# Reload NetworkManager configuration
sudo systemctl reload NetworkManager

# Enable wlan0 and eth1 devices
sudo nmcli radio wifi on
sudo nmcli device set wlan0 managed yes
sudo nmcli device set eth1 managed yes

# Bring up wlan0 and eth1 devices
sudo ip link set wlan0 up
sudo ip link set eth1 up

# Configure wlan0 (LAN interface) as an access point
sudo nmcli connection add type wifi ifname wlan0 con-name "$SSID" autoconnect yes ssid "$SSID"
sudo nmcli connection modify "$SSID" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
sudo nmcli connection modify "$SSID" ipv4.addresses "$IPV4_GATEWAY"
sudo nmcli connection modify "$SSID" ipv6.addresses "$IPV6_GATEWAY"
sudo nmcli connection modify "$SSID" ipv6.method shared
sudo nmcli connection modify "$SSID" wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify "$SSID" wifi-sec.proto rsn
sudo nmcli connection modify "$SSID" wifi-sec.group ccmp
sudo nmcli connection modify "$SSID" wifi-sec.pairwise ccmp
sudo nmcli connection modify "$SSID" wifi-sec.psk "$WIFI_PASSWORD"
sudo nmcli connection modify "$SSID" wifi-sec.pmf disable
sudo nmcli connection up "$SSID"

# Configure eth0 (WAN interface) to use DHCP
sudo nmcli connection add type ethernet ifname eth0 con-name eth0
sudo nmcli connection modify eth0 ipv4.method auto
sudo nmcli connection modify eth0 ipv6.method auto
sudo nmcli connection up eth0

# Configure eth1 (LAN interface) to use static IP
sudo nmcli connection add type ethernet ifname eth1 con-name eth1
sudo nmcli connection modify eth1 ipv4.addresses 192.168.4.2/24
sudo nmcli connection modify eth1 ipv4.method manual
sudo nmcli connection modify eth1 ipv6.method ignore
sudo nmcli connection up eth1

# Enable IP forwarding
sudo sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sed -i 's|#net.ipv6.conf.all.forwarding=1|net.ipv6.conf.all.forwarding=1|' /etc/sysctl.conf
sudo sysctl -p

# Set up iptables rules for NAT
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o eth1 -j ACCEPT
sudo iptables -A FORWARD -i eth1 -o wlan0 -j ACCEPT

sudo ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo ip6tables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo ip6tables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
sudo ip6tables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo ip6tables -A FORWARD -i eth1 -o eth0 -j ACCEPT
sudo ip6tables -A FORWARD -i wlan0 -o eth1 -j ACCEPT
sudo ip6tables -A FORWARD -i eth1 -o wlan0 -j ACCEPT

# Save iptables rules
sudo sh -c "iptables-save > /etc/iptables/rules.v4"
sudo sh -c "ip6tables-save > /etc/iptables/rules.v6"

# Create router-setup.sh script
cat <<EOF | sudo tee /usr/local/bin/router-setup.sh
#!/bin/bash

# Source the configuration file
source /opt/router-config.conf

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# Set up iptables rules for IPv4
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth1 -j ACCEPT
iptables -A FORWARD -i eth1 -o wlan0 -j ACCEPT

# Set up ip6tables rules for IPv6
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
ip6tables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -A FORWARD -i eth1 -o eth0 -j ACCEPT
ip6tables -A FORWARD -i wlan0 -o eth1 -j ACCEPT
ip6tables -A FORWARD -i eth1 -o wlan0 -j ACCEPT

# Logging network information
sleep 5
echo "Logging network information..."
nmcli con show
EOF

# Make the script executable
sudo chmod +x /usr/local/bin/router-setup.sh

# Create systemd service for router setup
cat <<EOF | sudo tee /etc/systemd/system/router.service
[Unit]
Description=Router Setup Service
After=network.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/router-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the router service
sudo systemctl daemon-reload
sudo systemctl enable router.service
sudo systemctl start router.service

# Reboot the system
sudo reboot
