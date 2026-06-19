#!/usr/bin/env bash
# Configure Nexus Phase 2 via az container exec — bypasses Cloudflare entirely.
#
# Uploads configure-nexus-inner.sh to the Nexus Azure Files share, then runs it
# inside the container against localhost:8081.  The admin password is passed as
# a base64-encoded env var so it never appears in the exec-command as plain text.
#
# Required env vars:
#   NEW_PASSWORD    Nexus admin password (already set by bootstrap)
#   RESOURCE_GROUP  Azure resource group name
#   CONTAINER_GROUP ACI container group name  (e.g. aci-prod-nexus-oss)
#   STORAGE_ACCOUNT Azure Storage account name
set -euo pipefail

: "${NEW_PASSWORD:?NEW_PASSWORD is required}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
: "${CONTAINER_GROUP:?CONTAINER_GROUP is required}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"

INNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure-nexus-inner.sh"

echo "Fetching storage account key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)

PW_B64=$(printf '%s' "$NEW_PASSWORD" | base64 | tr -d '\n')

echo "Uploading configuration script..."
az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name nexus-data \
  --source "$INNER" \
  --path configure-nexus-inner.sh \
  --output none

echo "Running configuration inside container..."
az container exec \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_GROUP" \
  --container-name nexus \
  --exec-command "env NX_PW_B64=${PW_B64} bash /nexus-data/configure-nexus-inner.sh"

echo "Cleaning up..."
az storage file delete \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name nexus-data \
  --path configure-nexus-inner.sh \
  --output none
