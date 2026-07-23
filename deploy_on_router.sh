#!/bin/sh
# deploy_on_router.sh - One-line deploy script to fetch VPN files from GitHub to OpenWrt

REPO_RAW="https://raw.githubusercontent.com/nickan/tg-ws-proxy/master"

echo "=== Deploying VLESS VPN from GitHub (nickan/tg-ws-proxy) ==="

# 1. Download configuration files from GitHub
echo "[*] Fetching singbox.json..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL -k "${REPO_RAW}/singbox.json" -o /etc/singbox.json
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -qO /etc/singbox.json "${REPO_RAW}/singbox.json"
fi

echo "[*] Fetching proxy_domains.txt..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL -k "${REPO_RAW}/proxy_domains.txt" -o /etc/proxy_domains.txt
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -qO /etc/proxy_domains.txt "${REPO_RAW}/proxy_domains.txt"
fi

echo "[*] Fetching start_singbox.sh..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL -k "${REPO_RAW}/start_singbox.sh" -o /etc/start_singbox.sh
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -qO /etc/start_singbox.sh "${REPO_RAW}/start_singbox.sh"
fi

chmod +x /etc/start_singbox.sh

# 2. Configure autostart in /etc/rc.local
if ! grep -q "start_singbox.sh" /etc/rc.local; then
    echo "[*] Injecting startup command into /etc/rc.local..."
    cp /etc/rc.local /etc/rc.local.bak 2>/dev/null || true
    head -n -1 /etc/rc.local > /tmp/rc.local.new
    echo "sh /etc/start_singbox.sh &" >> /tmp/rc.local.new
    echo "exit 0" >> /tmp/rc.local.new
    mv /tmp/rc.local.new /etc/rc.local
    chmod +x /etc/rc.local
    echo "[+] Autostart configured"
else
    echo "[*] Autostart already configured"
fi

# 3. Launch VPN
echo "[*] Starting sing-box VPN..."
sh /etc/start_singbox.sh

echo "=== Deployment from GitHub Completed! ==="
