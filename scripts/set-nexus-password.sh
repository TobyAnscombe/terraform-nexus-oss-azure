#!/usr/bin/env bash
# Bootstrap Nexus OSS via az container exec — bypasses Cloudflare entirely.
#
# Writes a temporary bash script to the Nexus Azure Files share (/nexus-data),
# runs it inside the container against localhost:8081, then deletes it.
# Using Azure ARM APIs means corporate network proxies and Cloudflare Bot Fight
# Mode do not interfere.
#
# Required env vars:
#   NEW_PASSWORD    Target admin password
#   RESOURCE_GROUP  Azure resource group name
#   CONTAINER_GROUP Azure Container Instance group name
#   STORAGE_ACCOUNT Azure Storage account name (for the nexus-data file share)
set -euo pipefail

: "${NEW_PASSWORD:?NEW_PASSWORD is required}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
: "${CONTAINER_GROUP:?CONTAINER_GROUP is required}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"

# Fetch the storage account key so we can upload the bootstrap script.
echo "Fetching storage account key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)

# Write bootstrap script to a local temp file.
# The password is embedded as a bash variable so curl arguments never contain
# unescaped special characters.  The file is deleted immediately after use.
tmpfile=$(mktemp /tmp/nexus-bootstrap-XXXXXX.sh)
trap 'rm -f "$tmpfile"' EXIT

# Escape any single quotes in the password for embedding inside a bash
# single-quoted string: replace ' with '\'' (end-quote, escaped-quote, re-open).
escaped_pw="${NEW_PASSWORD//\'/\'\\\'\'}"

cat > "$tmpfile" <<BOOTEOF
#!/bin/bash
# Runs inside the Nexus container against localhost:8081 — no Cloudflare involved.
PW='$escaped_pw'
url='http://localhost:8081'

# Step 1: accept EULA (required since Nexus CE; idempotent).
curl -sf -u admin:admin123 -X PUT "\$url/service/rest/v1/system/eula" \
  -H 'Content-Type: application/json' -d '{"accepted":true}' \
|| curl -sf -u "admin:\$PW" -X PUT "\$url/service/rest/v1/system/eula" \
  -H 'Content-Type: application/json' -d '{"accepted":true}'
echo 'EULA accepted.'

# Step 2: change admin password (idempotent — falls back if already changed).
curl -sf -u admin:admin123 -X PUT "\$url/service/rest/v1/security/users/admin/change-password" \
  -H 'Content-Type: text/plain' -d "\$PW" \
|| curl -sf -u "admin:\$PW" -X PUT "\$url/service/rest/v1/security/users/admin/change-password" \
  -H 'Content-Type: text/plain' -d "\$PW"
echo 'Nexus admin password set.'
BOOTEOF

echo "Uploading bootstrap script to Azure Files..."
az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name nexus-data \
  --source "$tmpfile" \
  --path bootstrap-tmp.sh \
  --output none

echo "Running bootstrap inside container..."
az container exec \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_GROUP" \
  --container-name nexus \
  --exec-command "bash /nexus-data/bootstrap-tmp.sh"

echo "Cleaning up bootstrap script..."
az storage file delete \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name nexus-data \
  --path bootstrap-tmp.sh \
  --output none
