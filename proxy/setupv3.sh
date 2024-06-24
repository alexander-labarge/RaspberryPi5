#!/bin/bash

# Update and install required packages
sudo apt update
sudo apt install -y dnsmasq iptables-persistent network-manager

# Ensure NetworkManager is enabled and running
sudo systemctl enable NetworkManager
sudo systemctl start NetworkManager

# Delete existing connections and configurations
sudo nmcli connection delete Deathstar || true
sudo nmcli connection delete eth0 || true
sudo nmcli connection delete wlan0 || true

# Clean up old dnsmasq configurations
sudo rm -f /etc/dnsmasq.conf

# Ensure NetworkManager manages wlan0
sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf <<EOF
[keyfile]
unmanaged-devices=none
EOF

# Reload NetworkManager configuration
sudo systemctl reload NetworkManager
0
# Enable wlan0 device
sudo nmcli radio wifi on
sudo nmcli device set wlan0 managed yes

# Configure wlan0 (LAN interface) as an access point
sudo nmcli connection add type wifi ifname wlan0 con-name Deathstar autoconnect yes ssid Deathstar
sudo nmcli connection modify Deathstar 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
sudo nmcli connection modify Deathstar ipv4.addresses 192.168.4.1/24
sudo nmcli connection modify Deathstar ipv6.addresses fd00::1/64
sudo nmcli connection modify Deathstar ipv6.method shared
sudo nmcli connection modify Deathstar wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify Deathstar wifi-sec.psk P@ssword123!
sudo nmcli connection modify Deathstar wifi-sec.pmf required
# during testing - was an issue with encryption on pi5 arm64
#sudo nmcli connection modify Deathstar wifi-sec.pmf disable
sudo nmcli connection up Deathstar

# Configure eth0 (WAN interface) to use DHCP
sudo nmcli connection add type ethernet ifname eth0 con-name eth0
sudo nmcli connection modify eth0 ipv4.method auto
sudo nmcli connection modify eth0 ipv6.method auto
sudo nmcli connection up eth0

# Configure dnsmasq
cat <<EOF | sudo tee /etc/dnsmasq.conf
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
dhcp-range=fd00::2,fd00::20,12h
EOF

# Enable dnsmasq service
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

# Enable IP forwarding
sudo sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sed -i 's|#net.ipv6.conf.all.forwarding=1|net.ipv6.conf.all.forwarding=1|' /etc/sysctl.conf
sudo sysctl -p

# Set up iptables rules for NAT
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

sudo ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo ip6tables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo ip6tables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Save iptables rules
sudo sh -c "iptables-save > /etc/iptables/rules.v4"
sudo sh -c "ip6tables-save > /etc/iptables/rules.v6"

# Create router-setup.sh script
cat <<EOF | sudo tee /usr/local/bin/router-setup.sh
#!/bin/bash

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# Set up iptables rules for IPv4
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Set up ip6tables rules for IPv6
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Restart dnsmasq to apply any changes
systemctl restart dnsmasq
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
