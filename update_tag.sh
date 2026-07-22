#!/bin/sh
# Update RELEASE_TAG to v0.2.2 in /etc/rc.local
sed -i 's/RELEASE_TAG="v0\.1\.9"/RELEASE_TAG="v0.2.2"/' /etc/rc.local
echo "Updated tag in rc.local:"
grep "RELEASE_TAG" /etc/rc.local
