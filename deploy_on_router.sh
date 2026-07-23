#!/bin/sh
# deploy_on_router.sh - Deploy script with OpenWrt LuCI web service integration

REPO_RAW="https://raw.githubusercontent.com/nickan/tg-ws-proxy/master"
CACHE_BUSTER=$(date +%s)

echo "=== Deploying VLESS VPN from GitHub (nickan/tg-ws-proxy) ==="

# 1. Download configuration files from GitHub (bypassing CDN cache)
echo "[*] Fetching singbox.json..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL -k -H "Cache-Control: no-cache" "${REPO_RAW}/singbox.json?t=${CACHE_BUSTER}" -o /etc/singbox.json
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate --no-cache -qO /etc/singbox.json "${REPO_RAW}/singbox.json?t=${CACHE_BUSTER}"
fi

echo "[*] Fetching proxy_domains.txt..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL -k -H "Cache-Control: no-cache" "${REPO_RAW}/proxy_domains.txt?t=${CACHE_BUSTER}" -o /etc/proxy_domains.txt
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate --no-cache -qO /etc/proxy_domains.txt "${REPO_RAW}/proxy_domains.txt?t=${CACHE_BUSTER}"
fi

echo "[*] Fetching start_singbox.sh..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL -k -H "Cache-Control: no-cache" "${REPO_RAW}/start_singbox.sh?t=${CACHE_BUSTER}" -o /etc/start_singbox.sh
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate --no-cache -qO /etc/start_singbox.sh "${REPO_RAW}/start_singbox.sh?t=${CACHE_BUSTER}"
fi

chmod +x /etc/start_singbox.sh

# 2. Create OpenWrt Init Service (/etc/init.d/singbox) for LuCI control
cat <<'EOF' > /etc/init.d/singbox
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

start_service() {
    sh /etc/start_singbox.sh
}

stop_service() {
    echo "[*] Stopping sing-box VPN..."
    PID_FILE="/tmp/sing-box.pid"
    if [ -f "${PID_FILE}" ]; then
        OLD_PID=$(cat "${PID_FILE}")
        kill "${OLD_PID}" 2>/dev/null || true
        rm -f "${PID_FILE}"
    fi
    killall -q sing-box 2>/dev/null || true
    echo "[+] sing-box VPN stopped"
}

restart_service() {
    stop_service
    sleep 1
    start_service
}
EOF

chmod +x /etc/init.d/singbox
/etc/init.d/singbox enable 2>/dev/null || true

# 3. Configure autostart in /etc/rc.local if not already done
if ! grep -q "start_singbox.sh" /etc/rc.local; then
    echo "[*] Injecting startup command into /etc/rc.local..."
    cp /etc/rc.local /etc/rc.local.bak 2>/dev/null || true
    head -n -1 /etc/rc.local > /tmp/rc.local.new
    echo "sh /etc/start_singbox.sh &" >> /tmp/rc.local.new
    echo "exit 0" >> /tmp/rc.local.new
    mv /tmp/rc.local.new /etc/rc.local
    chmod +x /etc/rc.local
    echo "[+] Autostart configured"
fi

# 4. Launch VPN
echo "[*] Starting sing-box VPN..."
sh /etc/start_singbox.sh

echo "=== Deployment from GitHub Completed! ==="
echo "[+] Service 'singbox' added to OpenWrt LuCI (System -> Startup)"
