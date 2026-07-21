#!/bin/sh
# =============================================================================
#  tg-ws-proxy autostart for OpenWrt (aarch64 / Mediatek Filogic)
#  Place this block in /etc/rc.local BEFORE the final "exit 0" line.
#
#  Requirements:
#    - curl OR wget must be available (standard in OpenWrt)
#    - uci available (standard in OpenWrt) for firewall rule injection
#    - /tmp lives in RAM — no flash wear, no /overlay consumption
#
#  Usage:
#    1. Upload this script to the router:
#         scp rc.local.snippet root@192.168.1.1:/tmp/
#    2. Append to /etc/rc.local:
#         cat /tmp/rc.local.snippet >> /etc/rc.local
#         # or paste the ( ... ) & block manually before "exit 0"
# =============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
TG_PROXY_PORT="8443"
TG_PROXY_SECRET="ee155b2ebbd93854830e71195db68a6cdd"

# GitHub Releases download URL — update tag on new release
# Format: https://github.com/<owner>/<repo>/releases/download/<tag>/<binary>
GITHUB_REPO="nickan/tg-ws-proxy"
RELEASE_TAG="v0.1.0"
BINARY_NAME="tg-ws-proxy-aarch64-musl"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${BINARY_NAME}"

# Target path in RAM (tmpfs) — never touches /overlay flash
PROXY_BIN="/tmp/tg-ws-proxy"

# Minimum acceptable binary size in bytes (reject 0-byte / partial downloads)
MIN_BINARY_SIZE=102400    # 100 KB — a valid musl binary will be >> this

# Network wait: give WAN/Wi-Fi time to initialize (seconds)
BOOT_DELAY=20

# PID file for idempotent restarts
PID_FILE="/tmp/tg-ws-proxy.pid"

# Log file (also in RAM)
LOG_FILE="/tmp/tg-ws-proxy.log"

# Firewall rule name (uci)
FW_RULE_NAME="tg_ws_proxy_wan_in"

# ─────────────────────────────────────────────────────────────────────────────
# Run the entire startup in a detached background subshell so rc.local
# returns immediately and does NOT block the boot sequence.
# ─────────────────────────────────────────────────────────────────────────────
(
    # ── Redirect all output to log file ─────────────────────────────────────
    exec >> "${LOG_FILE}" 2>&1
    echo "=== tg-ws-proxy startup: $(date) ==="

    # ── 1. Wait for network initialization ──────────────────────────────────
    echo "[*] Waiting ${BOOT_DELAY}s for network to stabilize…"
    sleep "${BOOT_DELAY}"

    # Quick connectivity check — ping Telegram's anycast before downloading
    PING_TARGET="149.154.167.51"
    if ! ping -c 2 -W 3 "${PING_TARGET}" > /dev/null 2>&1; then
        echo "[!] No route to Telegram DC — waiting 30s more…"
        sleep 30
        if ! ping -c 2 -W 3 "${PING_TARGET}" > /dev/null 2>&1; then
            echo "[!] Network still unreachable — aborting."
            exit 1
        fi
    fi
    echo "[+] Network OK"

    # ── 2. Kill any stale instance ───────────────────────────────────────────
    if [ -f "${PID_FILE}" ]; then
        OLD_PID=$(cat "${PID_FILE}")
        if kill -0 "${OLD_PID}" 2>/dev/null; then
            echo "[*] Stopping previous instance (PID ${OLD_PID})…"
            kill "${OLD_PID}" 2>/dev/null
            sleep 1
        fi
        rm -f "${PID_FILE}"
    fi
    # Belt-and-suspenders: kill any stray process by name
    killall -q tg-ws-proxy 2>/dev/null

    # ── 3. Download binary to RAM ────────────────────────────────────────────
    #
    # GitHub Releases issues 302 redirects to amazonaws.com CDN.
    # We must follow redirects AND accept the CDN's cert (GitHub's cert
    # is fine; the CDN cert is from Amazon, which musl-based wget may reject).
    #
    echo "[*] Downloading ${BINARY_NAME} from GitHub…"

    DOWNLOAD_OK=0

    # Attempt 1 — curl (preferred: handles redirects and certs reliably)
    if command -v curl > /dev/null 2>&1; then
        curl \
            --location \
            --insecure \
            --silent \
            --show-error \
            --connect-timeout 20 \
            --max-time 120 \
            --retry 3 \
            --retry-delay 5 \
            --output "${PROXY_BIN}" \
            "${DOWNLOAD_URL}" \
            && DOWNLOAD_OK=1
        [ "${DOWNLOAD_OK}" -eq 0 ] && echo "[!] curl download failed"
    fi

    # Attempt 2 — wget fallback
    if [ "${DOWNLOAD_OK}" -eq 0 ] && command -v wget > /dev/null 2>&1; then
        wget \
            --no-check-certificate \
            --quiet \
            --tries=3 \
            --timeout=20 \
            --output-document="${PROXY_BIN}" \
            "${DOWNLOAD_URL}" \
            && DOWNLOAD_OK=1
        [ "${DOWNLOAD_OK}" -eq 0 ] && echo "[!] wget download also failed"
    fi

    if [ "${DOWNLOAD_OK}" -eq 0 ]; then
        echo "[!] All download attempts failed — aborting."
        rm -f "${PROXY_BIN}"
        exit 1
    fi

    # ── 4. Validate downloaded binary ────────────────────────────────────────
    if [ ! -f "${PROXY_BIN}" ]; then
        echo "[!] Binary not found after download — aborting."
        exit 1
    fi

    ACTUAL_SIZE=$(wc -c < "${PROXY_BIN}" 2>/dev/null || echo 0)
    echo "[*] Downloaded size: ${ACTUAL_SIZE} bytes"

    if [ "${ACTUAL_SIZE}" -lt "${MIN_BINARY_SIZE}" ]; then
        echo "[!] Binary too small (${ACTUAL_SIZE} B < ${MIN_BINARY_SIZE} B) — likely a partial/error response."
        echo "[!] First 256 bytes of downloaded content:"
        head -c 256 "${PROXY_BIN}" 2>/dev/null || true
        rm -f "${PROXY_BIN}"
        exit 1
    fi

    # Sanity check: ELF magic bytes (0x7f 'E' 'L' 'F')
    ELF_MAGIC=$(head -c 4 "${PROXY_BIN}" | od -An -tx1 | tr -d ' \n')
    if [ "${ELF_MAGIC}" != "7f454c46" ]; then
        echo "[!] Downloaded file is not an ELF binary (magic=${ELF_MAGIC}) — corrupted download?"
        rm -f "${PROXY_BIN}"
        exit 1
    fi

    echo "[+] Binary validated OK"

    # ── 5. Make executable ───────────────────────────────────────────────────
    chmod +x "${PROXY_BIN}"

    # ── 6. Configure firewall — open port 8443 on WAN ────────────────────────
    #
    # OpenWrt uses nftables (fw4) since 22.03. UCI is the portable interface.
    # We check if the rule already exists to keep the script idempotent.
    #
    EXISTING_RULE=$(uci show firewall 2>/dev/null | grep -F "name='${FW_RULE_NAME}'" | head -1)

    if [ -z "${EXISTING_RULE}" ]; then
        echo "[*] Adding firewall rule for port ${TG_PROXY_PORT} on WAN…"

        # Add new rule section
        uci add firewall rule
        uci set firewall.@rule[-1].name="${FW_RULE_NAME}"
        uci set firewall.@rule[-1].src="wan"
        uci set firewall.@rule[-1].dest_port="${TG_PROXY_PORT}"
        uci set firewall.@rule[-1].proto="tcp"
        uci set firewall.@rule[-1].target="ACCEPT"
        uci set firewall.@rule[-1].enabled="1"
        uci commit firewall

        # Reload firewall rules (fw4 for OpenWrt 22.03+, iptables for older)
        if command -v fw4 > /dev/null 2>&1; then
            fw4 reload
        elif /etc/init.d/firewall restart > /dev/null 2>&1; then
            echo "[+] Firewall restarted (iptables path)"
        else
            echo "[!] Could not reload firewall — may need manual reload"
        fi

        echo "[+] Firewall rule '${FW_RULE_NAME}' added"
    else
        echo "[*] Firewall rule '${FW_RULE_NAME}' already exists — skipping"
    fi

    # ── 7. Launch proxy in background ────────────────────────────────────────
    echo "[*] Starting tg-ws-proxy on port ${TG_PROXY_PORT}…"

    "${PROXY_BIN}" \
        --port  "${TG_PROXY_PORT}" \
        --secret "${TG_PROXY_SECRET}" \
        >> "${LOG_FILE}" 2>&1 &

    PROXY_PID=$!
    echo "${PROXY_PID}" > "${PID_FILE}"

    echo "[+] tg-ws-proxy started (PID ${PROXY_PID})"
    echo "[+] Proxy link: tg://proxy?server=$(uci get network.wan.ipaddr 2>/dev/null || echo YOUR_IP)&port=${TG_PROXY_PORT}&secret=${TG_PROXY_SECRET}"

) &
# ─────────────────────────────────────────────────────────────────────────────
# End of tg-ws-proxy autostart block
# ─────────────────────────────────────────────────────────────────────────────

exit 0
