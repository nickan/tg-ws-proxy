#!/bin/sh
for dom in cakeisalie.co.uk noskomnadzor.co.uk pyatdesyatdva.co.uk notelega.co.uk; do
    echo "=== ${dom} ==="
    curl -i -k -m 4 "https://${dom}/" 2>&1 | head -n 10
done
