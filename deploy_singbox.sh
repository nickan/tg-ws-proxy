#!/bin/sh
# deploy_singbox.sh - Deploy sing-box VPN and custom domain list to OpenWrt router

ROUTER_IP="192.168.1.1"
ROUTER_USER="root"
CONFIG_FILE="singbox.json"
DOMAIN_FILE="proxy_domains.txt"
START_SCRIPT="start_singbox.sh"

echo "=== Deploying sing-box VPN to OpenWrt ($ROUTER_IP) ==="

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[!] Error: Local config $CONFIG_FILE not found!"
    exit 1
fi

if [ ! -f "$DOMAIN_FILE" ]; then
    echo "[!] Error: Local domain list $DOMAIN_FILE not found!"
    exit 1
fi

if [ ! -f "$START_SCRIPT" ]; then
    echo "[!] Error: Local script $START_SCRIPT not found!"
    exit 1
fi

echo "[*] Uploading configuration file..."
scp "$CONFIG_FILE" "${ROUTER_USER}@${ROUTER_IP}:/etc/singbox.json"

echo "[*] Uploading domain list..."
scp "$DOMAIN_FILE" "${ROUTER_USER}@${ROUTER_IP}:/etc/proxy_domains.txt"

echo "[*] Uploading startup script..."
scp "$START_SCRIPT" "${ROUTER_USER}@${ROUTER_IP}:/etc/start_singbox.sh"

echo "[*] Configuring and executing on router..."
ssh "${ROUTER_USER}@${ROUTER_IP}" '
chmod +x /etc/start_singbox.sh

if ! grep -q "start_singbox.sh" /etc/rc.local; then
    echo "[*] Injecting startup command into /etc/rc.local..."
    cp /etc/rc.local /etc/rc.local.bak 2>/dev/null || true
    head -n -1 /etc/rc.local > /tmp/rc.local.new
    echo "sh /etc/start_singbox.sh &" >> /tmp/rc.local.new
    echo "exit 0" >> /tmp/rc.local.new
    mv /tmp/rc.local.new /etc/rc.local
    chmod +x /etc/rc.local
    echo "[+] Autostart configured in /etc/rc.local"
else
    echo "[*] Autostart already configured in /etc/rc.local"
fi

echo "[*] Executing /etc/start_singbox.sh..."
sh /etc/start_singbox.sh
'

echo "=== Deployment Completed Successfully! ==="
echo "Check logs with: ssh ${ROUTER_USER}@${ROUTER_IP} 'tail -f /tmp/sing-box.log'"
