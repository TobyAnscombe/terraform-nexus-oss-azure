#!/usr/bin/env bash
# Bootstrap a fresh Nexus OSS instance:
#   1. Accept the EULA (required since Nexus CE; idempotent).
#   2. Change the admin password from the default (admin123) to NEW_PASSWORD.
#
# Both steps are idempotent — safe to re-run at any time.
#
# Required env vars:
#   NEXUS_URL      Base URL, e.g. https://nexus.example.com
#   NEW_PASSWORD   Target admin password
#
# Optional env vars (Cloudflare Access service token):
#   CF_ACCESS_CLIENT_ID
#   CF_ACCESS_CLIENT_SECRET
set -euo pipefail

: "${NEXUS_URL:?NEXUS_URL is required}"
: "${NEW_PASSWORD:?NEW_PASSWORD is required}"

base="${NEXUS_URL%/}"

cf_args=()
if [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]]; then
  : "${CF_ACCESS_CLIENT_SECRET:?CF_ACCESS_CLIENT_SECRET required when CF_ACCESS_CLIENT_ID is set}"
  cf_args=(
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}"
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}"
  )
fi

# Step 1 — accept EULA (Nexus CE blocks all repository access until accepted).
curl -sf ${cf_args[@]+"${cf_args[@]}"} \
  -u "admin:admin123" \
  -X PUT "${base}/service/rest/v1/system/eula" \
  -H "Content-Type: application/json" \
  -d '{"accepted":true}' \
|| \
curl -sf ${cf_args[@]+"${cf_args[@]}"} \
  -u "admin:${NEW_PASSWORD}" \
  -X PUT "${base}/service/rest/v1/system/eula" \
  -H "Content-Type: application/json" \
  -d '{"accepted":true}'

echo "EULA accepted."

# Step 2 — change admin password.
curl -sf ${cf_args[@]+"${cf_args[@]}"} \
  -u "admin:admin123" -X PUT "${base}/service/rest/v1/security/users/admin/change-password" \
  -H "Content-Type: text/plain" -d "${NEW_PASSWORD}" \
|| \
curl -sf ${cf_args[@]+"${cf_args[@]}"} \
  -u "admin:${NEW_PASSWORD}" -X PUT "${base}/service/rest/v1/security/users/admin/change-password" \
  -H "Content-Type: text/plain" -d "${NEW_PASSWORD}"

echo "Nexus admin password set."
