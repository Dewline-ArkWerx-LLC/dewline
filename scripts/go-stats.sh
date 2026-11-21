#!/bin/bash
# Prints clicks on /download and the /go/ short links per day, from the dewline_go Analytics Engine dataset that
# site/worker.js writes. Needs CLOUDFLARE_API_TOKEN with Account Analytics Read. Usage: go-stats.sh [days, default 30]
set -euo pipefail
days=${1:-30}
[[ $days =~ ^[0-9]+$ ]] || { echo "usage: go-stats.sh [days]" >&2; exit 2; }
: "${CLOUDFLARE_API_TOKEN:?needs a Cloudflare API token with Account Analytics Read}"
account=${CLOUDFLARE_ACCOUNT_ID:-fe536dbb39f23e95cc80475f9d2772bb}
curl -fsS --proto '=https' "https://api.cloudflare.com/client/v4/accounts/$account/analytics_engine/sql" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    --data "SELECT toDate(timestamp) AS day, blob1 AS link, blob2 AS referrer, blob3 AS country, SUM(_sample_interval) AS clicks
FROM dewline_go WHERE timestamp > NOW() - INTERVAL '$days' DAY
GROUP BY day, link, referrer, country ORDER BY day DESC, clicks DESC FORMAT TabSeparatedWithNames"
