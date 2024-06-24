#!/bin/bash

# Create logging script
cat <<EOF | sudo tee /usr/local/bin/network-logging.sh
#!/bin/bash

# Create a directory for log files
mkdir -p /var/log/network-logs

# Wait for the wlan0 interface to0 be up
sleep 10

# Start tcpdump to log DNS, DHCP, TCP, HTTP, and HTTPS traffic connection information only
tcpdump -i wlan0 -s 96 -l -n 'port 53 or port 67 or port 68 or port 80 or port 443' -A > /var/log/network-logs/network_traffic.log &
EOF

# Make the logging script executable
sudo chmod +x /usr/local/bin/network-logging.sh

# Create systemd service for network logging
cat <<EOF | sudo tee /etc/systemd/system/network-logging.service
[Unit]
Description=Network Logging Service
After=router.service network.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/network-logging.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the network logging service
sudo systemctl daemon-reload
sudo systemctl enable network-logging.service
sudo systemctl start network-logging.service

# Install logrotate
sudo apt update
sudo apt install -y logrotate

# Create logrotate configuration
sudo tee /etc/logrotate.d/network-logs <<EOF
/var/log/network-logs/network_traffic.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    size 10M
    create 0640 root adm
    postrotate
        systemctl restart network-logging.service > /dev/null 2>&1 || true
    endscript
}
EOF

# Reboot the system
sudo reboot
