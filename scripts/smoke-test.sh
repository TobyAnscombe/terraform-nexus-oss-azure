#!/usr/bin/env bash
# End-to-end smoke test for the Nexus OSS deployment.
#
# Usage:
#   ./scripts/smoke-test.sh
#   ./scripts/smoke-test.sh http://nexus-oss-abc123.uksouth.azurecontainer.io
#
# Phase 1 checks: need infra/ applied.
# Phase 2 checks: need nexus/ applied (repos, routing rules, anonymous access).

set -euo pipefail

NEXUS_URL="${1:-}"

# ── Resolve URL ──────────────────────────────────────────────────────────────
if [[ -z "$NEXUS_URL" ]]; then
  NEXUS_URL=$(cd "$(dirname "$0")/../infra" && terraform output -raw nexus_url 2>/dev/null || true)
fi
if [[ -z "$NEXUS_URL" ]]; then
  echo "ERROR: Nexus URL not found. Pass it as first argument or run infra/ apply first." >&2
  exit 1
fi
NEXUS_URL="${NEXUS_URL%/}"

# ── Helpers ──────────────────────────────────────────────────────────────────
pass=0
fail=0
GREEN='\033[0;32m'
RED='\033[0;31m'
GRAY='\033[0;90m'
RESET='\033[0m'

check() {
  local label="$1" url="$2"
  shift 2
  local expect=("${@:-200}")

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

  local ok=false
  for e in "${expect[@]}"; do
    [[ "$code" == "$e" ]] && ok=true && break
  done

  if $ok; then
    printf "  ${GREEN}[PASS]${RESET} %s\n" "$label"
    pass=$((pass+1))
  else
    local want
    want=$(IFS='/'; echo "${expect[*]}")
    printf "  ${RED}[FAIL]${RESET} %s  (HTTP %s, expected %s)\n" "$label" "$code" "$want"
    printf "         ${GRAY}%s${RESET}\n" "$url"
    fail=$((fail+1))
  fi
}

# ── Checks ───────────────────────────────────────────────────────────────────
echo ""
echo "Nexus smoke test  $NEXUS_URL"
printf '%0.s─' {1..60}; echo ""

echo ""
echo "Phase 1 — infrastructure"
check "Nexus up (Cloudflare Tunnel → Nexus)"   "$NEXUS_URL/service/rest/v1/status"

echo ""
echo "Phase 2 — Nexus configuration"
check "PyPI group index (anonymous read)"      "$NEXUS_URL/repository/pypi-group/simple/"
check "Allowlisted package accessible (numpy)" "$NEXUS_URL/repository/pypi-group/simple/numpy/"
check "Blocked package denied (flask)"         "$NEXUS_URL/repository/pypi-group/simple/flask/" 403 404
check "CRAN PACKAGES index (anonymous read)"   "$NEXUS_URL/repository/r-group/src/contrib/PACKAGES.gz"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
printf '%0.s─' {1..60}; echo ""
if [[ $fail -eq 0 ]]; then
  printf "${GREEN}%d passed, %d failed${RESET}\n\n" "$pass" "$fail"
else
  printf "${RED}%d passed, %d failed${RESET}\n\n" "$pass" "$fail"
  exit 1
fi
