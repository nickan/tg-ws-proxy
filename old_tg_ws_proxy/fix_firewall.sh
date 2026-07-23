#!/bin/sh
echo "=== Adding firewall ACCEPT rule for port 8443 (WAN input) ==="

# Remove old broken rule if any
OLD=$(uci show firewall 2>/dev/null | grep "name='tg_ws_proxy_wan_in'" | sed "s/firewall\.\(.*\)\.name.*/\1/")
[ -n "$OLD" ] && uci delete firewall.$OLD 2>/dev/null && echo "Removed old rule"

# Add fresh rule
RULE=$(uci add firewall rule)
uci set firewall.$RULE.name='tg_ws_proxy_wan_in'
uci set firewall.$RULE.src='wan'
uci set firewall.$RULE.dest_port='8443'
uci set firewall.$RULE.proto='tcp'
uci set firewall.$RULE.target='ACCEPT'
uci set firewall.$RULE.enabled='1'
uci commit firewall

echo "UCI rule added:"
uci show firewall | grep -A6 "tg_ws_proxy"

echo ""
echo "=== Reloading firewall ==="
fw4 reload 2>/dev/null && echo "fw4 reload OK" || /etc/init.d/firewall restart && echo "firewall restart OK"

echo ""
echo "=== Verifying nftables after reload ==="
nft list ruleset 2>/dev/null | grep -B2 -A2 "8443" | grep -v "nozapret" | head -20

echo ""
echo "=== Done. Firewall rule for :8443 WAN input is active ==="
