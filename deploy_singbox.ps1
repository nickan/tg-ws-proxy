# deploy_singbox.ps1 - Deploys sing-box and its VPN configuration to an OpenWrt router.

$RouterIP = "192.168.1.1"
$RouterUser = "root"
$ConfigFile = "singbox.json"
$DomainFile = "proxy_domains.txt"
$StartScript = "start_singbox.sh"

Write-Host "=== Deploying sing-box VPN to OpenWrt ($RouterIP) ===" -ForegroundColor Cyan

# 1. Verify files exist locally
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Local configuration file '$ConfigFile' not found!"
    exit 1
}
if (-not (Test-Path $DomainFile)) {
    Write-Error "Local domain list '$DomainFile' not found!"
    exit 1
}
if (-not (Test-Path $StartScript)) {
    Write-Error "Local startup script '$StartScript' not found!"
    exit 1
}

# 2. Upload configuration file to /etc/singbox.json
Write-Host "[*] Uploading configuration file..." -ForegroundColor Yellow
Get-Content $ConfigFile -Raw -Encoding UTF8 | ssh "${RouterUser}@${RouterIP}" "cat > /etc/singbox.json"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upload configuration file!"
    exit 1
}
Write-Host "[+] Config uploaded to /etc/singbox.json" -ForegroundColor Green

# 3. Upload domain list to /etc/proxy_domains.txt
Write-Host "[*] Uploading domain list..." -ForegroundColor Yellow
Get-Content $DomainFile -Raw -Encoding UTF8 | ssh "${RouterUser}@${RouterIP}" "cat > /etc/proxy_domains.txt"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upload domain list!"
    exit 1
}
Write-Host "[+] Domain list uploaded to /etc/proxy_domains.txt" -ForegroundColor Green

# 4. Upload start script to /etc/start_singbox.sh
Write-Host "[*] Uploading startup script..." -ForegroundColor Yellow
Get-Content $StartScript -Raw -Encoding UTF8 | ssh "${RouterUser}@${RouterIP}" "cat > /etc/start_singbox.sh"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upload startup script!"
    exit 1
}
Write-Host "[+] Script uploaded to /etc/start_singbox.sh" -ForegroundColor Green

# 5. Make script executable and configure autostart via SSH
Write-Host "[*] Configuring and executing on router..." -ForegroundColor Yellow
$RemoteCommands = @'
chmod +x /etc/start_singbox.sh

if ! grep -q "start_singbox.sh" /etc/rc.local; then
    echo "[*] Injecting startup command into /etc/rc.local..."
    cp /etc/rc.local /etc/rc.local.bak 2>/dev/null || true
    head -n -1 /etc/rc.local > /tmp/rc.local.new
    echo "sh /etc/start_singbox.sh &" >> /tmp/rc.local.new
    echo "exit 0" >> /tmp/rc.local.new
    mv /tmp/rc.local.new /etc/rc.local
    chmod +x /etc/rc.local
    echo "[+] Autostart configured in /etc/rc.local"
else
    echo "[*] Autostart already configured in /etc/rc.local"
fi

echo "[*] Executing /etc/start_singbox.sh..."
sh /etc/start_singbox.sh
'@

ssh "${RouterUser}@${RouterIP}" $RemoteCommands
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to configure/run scripts on the router via SSH!"
    exit 1
}

Write-Host "=== Deployment Completed Successfully! ===" -ForegroundColor Green
Write-Host "You can check logs on the router using:" -ForegroundColor Gray
Write-Host "  ssh ${RouterUser}@${RouterIP} 'tail -f /tmp/sing-box.log'" -ForegroundColor Cyan
