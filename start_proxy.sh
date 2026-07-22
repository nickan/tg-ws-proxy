#!/bin/sh
# Fix ELF check in rc.local (od -> hexdump) and restart proxy

# Patch the line on the router
sed -i 's|head -c 4 "${PROXY_BIN}" | od -An -tx1 | tr -d .* \\\\n.|hexdump -n 4 -e '"'"'4/1 "%02x"'"'"' "${PROXY_BIN}" 2>/dev/null|' /etc/rc.local 2>/dev/null

# Simpler: just run the binary directly — it already downloaded OK (557 KB)
BIN="/tmp/tg-ws-proxy"
PORT="8443"
SECRET="ee155b2ebbd93854830e71195db68a6cdd"
PID_FILE="/tmp/tg-ws-proxy.pid"
LOG_FILE="/tmp/tg-ws-proxy.log"

# Kill old if running
killall -q tg-ws-proxy 2>/dev/null
sleep 1

# Force re-download by deleting old binary
rm -f "${BIN}"

if [ ! -f "${BIN}" ]; then
    echo "[!] Binary not in /tmp — downloading now..."
    curl -L --insecure --silent --show-error --connect-timeout 20 --max-time 60 \
        -o "${BIN}" \
        "https://github.com/nickan/tg-ws-proxy/releases/download/v0.2.1/tg-ws-proxy-aarch64-musl"
fi

echo "[*] Binary size: $(wc -c < "${BIN}") bytes"
echo "[*] ELF magic: $(hexdump -n 4 -e '4/1 "%02x"' "${BIN}" 2>/dev/null)"

chmod +x "${BIN}"

echo "[*] Starting proxy..."
"${BIN}" --port "${PORT}" --secret "${SECRET}" >> "${LOG_FILE}" 2>&1 &
PID=$!
echo "${PID}" > "${PID_FILE}"
sleep 2

echo ""
echo "=== Proxy started (PID ${PID}) ==="
ps | grep tg-ws | grep -v grep || echo "NOT RUNNING"
netstat -tlnp 2>/dev/null | grep 8443 || ss -tlnp 2>/dev/null | grep 8443 || echo "Port 8443: checking..."
echo ""
echo "=== Proxy log ==="
cat "${LOG_FILE}" 2>/dev/null
echo ""
echo "tg://proxy?server=46.147.216.14&port=8443&secret=${SECRET}"
