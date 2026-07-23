#!/bin/sh
echo "=== Test WSS with parameters ==="
curl -i -k -H "Upgrade: websocket" -H "Connection: Upgrade" "https://kws2.cakeisalie.co.uk/apiws?dst=149.154.167.220:443&dc=2"
