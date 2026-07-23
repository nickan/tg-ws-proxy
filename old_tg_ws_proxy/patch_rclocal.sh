#!/bin/sh
# Patch rc.local: replace od with hexdump
sed -i "s|head -c 4.*od -An -tx1.*tr -d.*|hexdump -n 4 -e '4/1 \"%02x\"' \"\${PROXY_BIN}\" 2>/dev/null)|" /etc/rc.local 2>/dev/null || true

# Direct sed on the exact line
sed -i 's/od -An -tx1/hexdump -n 4 -e '"'"'4\/1 "%02x"'"'"'/g' /etc/rc.local 2>/dev/null || true
sed -i '/head -c 4.*PROXY_BIN.*od/c\    ELF_MAGIC=$(hexdump -n 4 -e '"'"'4\/1 "%02x"'"'"' "${PROXY_BIN}" 2>\/dev\/null)' /etc/rc.local 2>/dev/null || true

echo "Fixed. Checking line:"
grep -n "ELF_MAGIC\|hexdump\|od -An" /etc/rc.local
