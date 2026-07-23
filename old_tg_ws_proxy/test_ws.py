import urllib.request
import urllib.error
import ssl
import socket

domains = [
    "cakeisalie.co.uk",
    "noskomnadzor.co.uk",
    "pyatdesyatdva.co.uk",
    "notelega.co.uk"
]

print("=== Starting diagnostics ===")

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

for dom in domains:
    for prefix in ["", "kws2.", "kws-dc2."]:
        host = f"{prefix}{dom}"
        url = f"https://{host}/apiws"
        print(f"\n[*] Trying {url} ...")
        try:
            # Resolve IP
            ips = socket.getaddrinfo(host, 443)
            ip = ips[0][4][0]
            print(f"    Resolved to {ip}")
            
            # Simple HTTP request with SSL context
            req = urllib.request.Request(
                url, 
                headers={
                    "User-Agent": "Mozilla/5.0",
                    "Host": host,
                    "Upgrade": "websocket",
                    "Connection": "Upgrade"
                }
            )
            resp = urllib.request.urlopen(req, context=ctx, timeout=5)
            print(f"    SUCCESS! Status: {resp.status}, Headers: {dict(resp.headers)}")
        except urllib.error.HTTPError as e:
            print(f"    HTTP Error: {e.code} {e.reason}")
            # Read response body if available
            try:
                print(f"    Body: {e.read()[:200]}")
            except Exception:
                pass
        except Exception as e:
            print(f"    Failed: {e}")
