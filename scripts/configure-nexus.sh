#!/usr/bin/env bash
# Configure Nexus Phase 2 via az container exec — bypasses Cloudflare entirely.
#
# Reads configure-nexus-inner.sh, prepends the admin password as a PW variable,
# uploads the combined script to the Nexus Azure Files share, runs it inside the
# container against localhost:8081, then deletes it.
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
if [[ ! -f "$INNER" ]]; then
  echo "ERROR: configure-nexus-inner.sh not found at $INNER" >&2
  exit 1
fi

echo "Fetching storage account key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)

# Escape any single quotes in the password for embedding inside a bash
# single-quoted string: replace ' with '\'' (end-quote, escaped-quote, re-open).
escaped_pw="${NEW_PASSWORD//\'/\'\\\'\'}"

# Build the combined script: password line first, then the inner script body
# (skip the inner script's shebang so it doesn't override ours).
tmpfile=$(mktemp /tmp/nexus-configure-XXXXXX.sh)
trap 'rm -f "$tmpfile"' EXIT

{
  echo "#!/bin/bash"
  echo "PW='${escaped_pw}'"
  tail -n +2 "$INNER"
} > "$tmpfile"

echo "Uploading configuration script..."
az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name nexus-data \
  --source "$tmpfile" \
  --path configure-nexus-tmp.sh \
  --output none

echo "Running configuration inside container..."
az container exec \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_GROUP" \
  --container-name nexus \
  --exec-command "bash /nexus-data/configure-nexus-tmp.sh"

echo "Cleaning up..."
az storage file delete \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name nexus-data \
  --path configure-nexus-tmp.sh \
  --output none
