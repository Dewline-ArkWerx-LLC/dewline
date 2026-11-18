#!/bin/bash
# Writes the newest stable version in site/appcast.xml into every site page's <span data-version> element, so the
# deployed site names the release the feed offers. Deploys run it after putting the released feed in site/.
set -euo pipefail
fail() { echo "stamp-site-version.sh: $*" >&2; exit 1; }
cd "$(dirname "$0")/../site"
version=$(python3 -I - appcast.xml <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
stable = [i for i in ET.parse(sys.argv[1]).iter("item") if i.find(ns + "channel") is None]
if stable:
    print(max(stable, key=lambda i: int(i.findtext(ns + "version"))).findtext(ns + "shortVersionString") or "")
EOF
)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "appcast.xml has no stable shortVersionString"
pages=$(grep -rl --include='*.html' '<span data-version>' .) || fail "no page has a <span data-version> element"
for page in $pages; do
    sed -i.bak -E "s|(<span data-version>)[^<]*(</span>)|\1$version\2|g" "$page"
    rm "$page.bak"
done
echo "stamp-site-version.sh: $version in ${pages//$'\n'/ }"
