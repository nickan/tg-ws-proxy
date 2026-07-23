#!/bin/sh
# deploy.sh — runs ON THE ROUTER via ssh pipe
# Installs tg-ws-proxy startup block into /etc/rc.local

set -e

SNIPPET_URL="https://raw.githubusercontent.com/nickan/tg-ws-proxy/master/rc.local.snippet.sh"
RC_LOCAL="/etc/rc.local"
MARKER="tg-ws-proxy autostart"

echo "[deploy] Router info: $(uname -m) / $(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d= -f2)"

# Already installed?
if grep -q "$MARKER" "$RC_LOCAL" 2>/dev/null; then
    echo "[deploy] Already installed in $RC_LOCAL — skipping."
    exit 0
fi

echo "[deploy] Downloading startup snippet…"
if command -v curl > /dev/null 2>&1; then
    curl -fsSL --insecure -o /tmp/tg_snippet.sh "$SNIPPET_URL"
else
    wget -q --no-check-certificate -O /tmp/tg_snippet.sh "$SNIPPET_URL"
fi

# Validate snippet downloaded correctly
if [ ! -s /tmp/tg_snippet.sh ]; then
    echo "[deploy] ERROR: Failed to download snippet"
    exit 1
fi

echo "[deploy] Injecting into $RC_LOCAL…"
# Backup original
cp "$RC_LOCAL" "${RC_LOCAL}.bak" 2>/dev/null || true

# Remove last line (exit 0), append snippet (which ends with exit 0)
head -n -1 "$RC_LOCAL" > /tmp/rc_local_new.sh
cat /tmp/tg_snippet.sh >> /tmp/rc_local_new.sh
mv /tmp/rc_local_new.sh "$RC_LOCAL"
chmod +x "$RC_LOCAL"

echo "[deploy] Done! Contents of $RC_LOCAL (last 10 lines):"
tail -10 "$RC_LOCAL"
echo ""
echo "[deploy] Testing rc.local syntax…"
sh -n "$RC_LOCAL" && echo "[deploy] Syntax OK"
echo ""
echo "[deploy] SUCCESS — proxy will start on next reboot."
echo "[deploy] To test without rebooting:"
echo "  sh /etc/rc.local &"
echo "  sleep 25 && tail -f /tmp/tg-ws-proxy.log"
