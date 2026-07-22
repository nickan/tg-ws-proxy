#!/bin/sh
# start_singbox.sh - OpenWrt script to download sing-box to /tmp and run VPN.
# Can be called manually or from /etc/rc.local.
#
# Runs in the background to prevent blocking boot sequence.

# --- Configuration ---
VERSION="1.11.4"
CONFIG_FILE="/etc/singbox.json"
BINARY_PATH="/tmp/sing-box"
LOG_FILE="/tmp/sing-box.log"
PID_FILE="/tmp/sing-box.pid"
BOOT_DELAY=15
MIN_BINARY_SIZE=5000000 # ~5MB

(
    # Redirect all output to log file
    exec >> "${LOG_FILE}" 2>&1
    echo "=== sing-box startup: $(date) ==="

    # 1. Wait for network to stabilize
    echo "[*] Waiting ${BOOT_DELAY}s for network to stabilize..."
    sleep "${BOOT_DELAY}"

    # Try pinging public DNS to verify internet connectivity
    PING_TARGET="1.1.1.1"
    if ! ping -c 2 -W 3 "${PING_TARGET}" > /dev/null 2>&1; then
        echo "[!] Internet unreachable — waiting 20s more..."
        sleep 20
        if ! ping -c 2 -W 3 "${PING_TARGET}" > /dev/null 2>&1; then
            echo "[!] Internet still unreachable — aborting start."
            exit 1
        fi
    fi
    echo "[+] Network is online"

    # 2. Kill any stale sing-box instance
    if [ -f "${PID_FILE}" ]; then
        OLD_PID=$(cat "${PID_FILE}")
        if kill -0 "${OLD_PID}" 2>/dev/null; then
            echo "[*] Stopping previous sing-box (PID ${OLD_PID})..."
            kill "${OLD_PID}" 2>/dev/null
            sleep 2
        fi
        rm -f "${PID_FILE}"
    fi
    killall -q sing-box 2>/dev/null || true

    # 3. Determine router architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            SINGBOX_ARCH="amd64"
            ;;
        aarch64)
            SINGBOX_ARCH="arm64"
            ;;
        armv7*)
            SINGBOX_ARCH="armv7"
            ;;
        *)
            echo "[!] Unknown architecture $ARCH. Defaulting to arm64."
            SINGBOX_ARCH="arm64"
            ;;
    esac

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SINGBOX_ARCH}.tar.gz"
    echo "[*] Target architecture: ${SINGBOX_ARCH}"

    # 4. Ensure TUN device node exists and is configured
    if [ ! -c /dev/net/tun ]; then
        echo "[*] TUN device node missing. Creating /dev/net/tun..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 666 /dev/net/tun 2>/dev/null || true
    fi
    # Try loading the tun module if it exists as a module
    modprobe tun 2>/dev/null || insmod tun 2>/dev/null || true

    # 5. Download and extract sing-box binary if not already present/valid
    DOWNLOAD_NEEDED=1
    if [ -f "${BINARY_PATH}" ]; then
        if "${BINARY_PATH}" version >/dev/null 2>&1; then
            echo "[+] Working sing-box binary already exists in /tmp"
            DOWNLOAD_NEEDED=0
        else
            echo "[!] Existing binary in /tmp is invalid. Deleting..."
            rm -f "${BINARY_PATH}"
        fi
    fi

    if [ "${DOWNLOAD_NEEDED}" -eq 1 ]; then
        echo "[*] Downloading sing-box v${VERSION} (${SINGBOX_ARCH}) from GitHub..."
        DOWNLOAD_OK=0
        
        # Attempt 1: curl
        if command -v curl > /dev/null 2>&1; then
            curl -L --insecure --silent --show-error --connect-timeout 20 --max-time 120 \
                -o /tmp/sing-box.tar.gz "${DOWNLOAD_URL}" && DOWNLOAD_OK=1
        fi
        
        # Attempt 2: wget
        if [ "${DOWNLOAD_OK}" -eq 0 ] && command -v wget > /dev/null 2>&1; then
            wget --no-check-certificate --quiet --timeout=20 \
                -O /tmp/sing-box.tar.gz "${DOWNLOAD_URL}" && DOWNLOAD_OK=1
        fi
        
        if [ "${DOWNLOAD_OK}" -eq 0 ]; then
            echo "[!] Download failed. Aborting."
            exit 1
        fi

        ACTUAL_SIZE=$(wc -c < /tmp/sing-box.tar.gz 2>/dev/null || echo 0)
        echo "[*] Downloaded archive size: ${ACTUAL_SIZE} bytes"
        
        if [ "${ACTUAL_SIZE}" -lt 100000 ]; then
            echo "[!] Archive is too small. Corrupted download?"
            rm -f /tmp/sing-box.tar.gz
            exit 1
        fi

        echo "[*] Extracting sing-box binary..."
        tar -zxf /tmp/sing-box.tar.gz -C /tmp
        
        EXTRACTED_DIR="/tmp/sing-box-${VERSION}-linux-${SINGBOX_ARCH}"
        if [ -f "${EXTRACTED_DIR}/sing-box" ]; then
            mv "${EXTRACTED_DIR}/sing-box" "${BINARY_PATH}"
            chmod +x "${BINARY_PATH}"
            echo "[+] Extracted and moved binary to ${BINARY_PATH}"
        else
            # Try finding it using wildcards
            FOUND_BIN=$(find /tmp/sing-box-* -name sing-box -type f 2>/dev/null | head -n 1)
            if [ -n "${FOUND_BIN}" ]; then
                mv "${FOUND_BIN}" "${BINARY_PATH}"
                chmod +x "${BINARY_PATH}"
                echo "[+] Found binary at ${FOUND_BIN} and moved to ${BINARY_PATH}"
            else
                echo "[!] Failed to find sing-box in extracted files."
                rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-* 2>/dev/null
                exit 1
            fi
        fi
        
        # Cleanup temp archive and folder
        rm -f /tmp/sing-box.tar.gz
        rm -rf /tmp/sing-box-${VERSION}-linux-${SINGBOX_ARCH} 2>/dev/null || true
        rm -rf /tmp/sing-box-* 2>/dev/null || true
    fi

    # 6. Configure firewall for tun0
    # Create a custom firewall zone 'singbox' mapping to 'tun0' and forward LAN traffic to it
    if ! uci show firewall 2>/dev/null | grep -q "name='singbox'"; then
        echo "[*] Creating firewall zone for singbox (tun0)..."
        uci add firewall zone
        uci set firewall.@zone[-1].name='singbox'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci add_list firewall.@zone[-1].device='tun0'
        
        # Allow LAN forwarding to the singbox zone
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        
        uci commit firewall
        
        if command -v fw4 > /dev/null 2>&1; then
            fw4 reload
        elif /etc/init.d/firewall restart > /dev/null 2>&1; then
            echo "[+] Firewall restarted (legacy path)"
        fi
        echo "[+] Firewall zone 'singbox' configured."
    else
        echo "[*] Firewall zone 'singbox' already exists — skipping configuration."
    fi

    # 7. Start sing-box VPN
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "[!] Configuration file ${CONFIG_FILE} not found. Cannot start VPN."
        exit 1
    fi

    echo "[*] Running configuration check..."
    if ! "${BINARY_PATH}" check -c "${CONFIG_FILE}"; then
        echo "[!] Configuration validation failed."
        exit 1
    fi

    echo "[*] Starting sing-box daemon..."
    "${BINARY_PATH}" run -c "${CONFIG_FILE}" >> "${LOG_FILE}" 2>&1 &
    
    NEW_PID=$!
    echo "${NEW_PID}" > "${PID_FILE}"
    echo "[+] sing-box running under PID ${NEW_PID}"
) &

exit 0
