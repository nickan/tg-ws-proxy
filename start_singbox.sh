#!/bin/sh
# start_singbox.sh - OpenWrt script to download sing-box to /tmp and run VPN.
# Automatically updates config and domain list from GitHub on launch.

VERSION="1.11.4"
CONFIG_FILE="/etc/singbox.json"
BINARY_PATH="/tmp/sing-box"
LOG_FILE="/tmp/sing-box.log"
PID_FILE="/tmp/sing-box.pid"
BOOT_DELAY=15
REPO_RAW="https://raw.githubusercontent.com/nickan/tg-ws-proxy/master"

generate_domain_ruleset() {
    DOMAIN_FILE="/etc/proxy_domains.txt"
    OUTPUT_FILE="/etc/singbox_domains.json"
    
    if [ ! -f "${DOMAIN_FILE}" ]; then
        echo "[!] ${DOMAIN_FILE} not found. Creating default list..."
        cat <<'EOF' > "${DOMAIN_FILE}"
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
anthropic.com
claude.ai
gemini.google.com
generativelanguage.googleapis.com
perplexity.ai
midjourney.com
deepseek.com
copilot.microsoft.com
t.me
telegram.org
telegram.me
EOF
    fi

    echo "[*] Parsing ${DOMAIN_FILE} -> ${OUTPUT_FILE}..."
    DOMAINS_JSON=""
    FIRST=1
    while IFS= read -r line || [ -n "$line" ]; do
        clean_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$clean_line" in
            ''|\#*) continue ;;
        esac
        
        if [ "$FIRST" -eq 1 ]; then
            DOMAINS_JSON="\"${clean_line}\""
            FIRST=0
        else
            DOMAINS_JSON="${DOMAINS_JSON}, \"${clean_line}\""
        fi
    done < "${DOMAIN_FILE}"

    cat <<EOF > "${OUTPUT_FILE}"
{
  "version": 2,
  "rules": [
    {
      "domain_suffix": [
        ${DOMAINS_JSON}
      ]
    }
  ]
}
EOF
    echo "[+] Generated domain rule-set (${OUTPUT_FILE})"
}

(
    # Redirect all output to log file
    exec >> "${LOG_FILE}" 2>&1
    echo "=== sing-box startup: $(date) ==="

    # 1. Check network connectivity (only sleep if network is not ready yet)
    PING_TARGET="1.1.1.1"
    if ! ping -c 1 -W 2 "${PING_TARGET}" > /dev/null 2>&1; then
        echo "[*] Waiting ${BOOT_DELAY}s for network to stabilize..."
        sleep "${BOOT_DELAY}"
        if ! ping -c 2 -W 3 "${PING_TARGET}" > /dev/null 2>&1; then
            echo "[!] Internet still unreachable — aborting start."
            exit 1
        fi
    fi
    echo "[+] Network is online"

    # 2. Try updating proxy_domains.txt and singbox.json from GitHub
    echo "[*] Checking GitHub (${REPO_RAW}) for config updates..."
    if command -v curl > /dev/null 2>&1; then
        curl -sSL -k --connect-timeout 10 "${REPO_RAW}/proxy_domains.txt" -o /tmp/proxy_domains.txt.new 2>/dev/null
        curl -sSL -k --connect-timeout 10 "${REPO_RAW}/singbox.json" -o /tmp/singbox.json.new 2>/dev/null
    elif command -v wget > /dev/null 2>&1; then
        wget --no-check-certificate -q -T 10 -O /tmp/proxy_domains.txt.new "${REPO_RAW}/proxy_domains.txt" 2>/dev/null
        wget --no-check-certificate -q -T 10 -O /tmp/singbox.json.new "${REPO_RAW}/singbox.json" 2>/dev/null
    fi

    if [ -s /tmp/proxy_domains.txt.new ]; then
        mv /tmp/proxy_domains.txt.new /etc/proxy_domains.txt
        echo "[+] Updated /etc/proxy_domains.txt from GitHub"
    else
        rm -f /tmp/proxy_domains.txt.new 2>/dev/null
    fi

    if [ -s /tmp/singbox.json.new ]; then
        mv /tmp/singbox.json.new /etc/singbox.json
        echo "[+] Updated /etc/singbox.json from GitHub"
    else
        rm -f /tmp/singbox.json.new 2>/dev/null
    fi

    # 3. Generate custom domain rule-set JSON from /etc/proxy_domains.txt
    generate_domain_ruleset

    # 4. Kill any stale sing-box instance
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

    # 5. Determine router architecture
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

    # 6. Ensure TUN device node exists and is configured
    if [ ! -c /dev/net/tun ]; then
        echo "[*] TUN device node missing. Creating /dev/net/tun..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 666 /dev/net/tun 2>/dev/null || true
    fi
    modprobe tun 2>/dev/null || insmod tun 2>/dev/null || true

    # 7. Download and extract sing-box binary if not already present/valid
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
        
        if command -v curl > /dev/null 2>&1; then
            curl -L --insecure --silent --show-error --connect-timeout 20 --max-time 120 \
                -o /tmp/sing-box.tar.gz "${DOWNLOAD_URL}" && DOWNLOAD_OK=1
        fi
        
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
        
        rm -f /tmp/sing-box.tar.gz
        rm -rf /tmp/sing-box-${VERSION}-linux-${SINGBOX_ARCH} 2>/dev/null || true
        rm -rf /tmp/sing-box-* 2>/dev/null || true
    fi

    # 8. Configure firewall for tun0
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

    # 9. Start sing-box VPN
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
