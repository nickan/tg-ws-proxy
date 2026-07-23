#!/bin/sh
echo "=== Check local port availability ==="
nc -z -w2 127.0.0.1 8443 && echo "Port 8443 is open on 127.0.0.1" || echo "Port 8443 is CLOSED on 127.0.0.1"
nc -z -w2 192.168.1.1 8443 && echo "Port 8443 is open on 192.168.1.1" || echo "Port 8443 is CLOSED on 192.168.1.1"

echo ""
echo "=== LAN interfaces and IPs ==="
ip addr show dev br-lan 2>/dev/null || ip addr show

echo ""
echo "=== Try connection using netcat to see log reaction ==="
# Send fake payload to trigger error in proxy logs
echo "HELLO" | nc -w2 127.0.0.1 8443
sleep 1

echo ""
echo "=== Proxy log tail (should show hello error now if reachable) ==="
tail -n 15 /tmp/tg-ws-proxy.log
