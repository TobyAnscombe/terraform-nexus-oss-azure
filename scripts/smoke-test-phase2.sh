#!/usr/bin/env bash
# Phase 2 smoke test — validates Nexus configuration applied by nexus/main.tf.
#
# Usage:
#   ./scripts/smoke-test-phase2.sh
#   ./scripts/smoke-test-phase2.sh <nexus-url> <admin-password>
#
# Checks anonymous access, allowlist routing, repo existence, routing rules,
# and admin password change.

set -euo pipefail

NEXUS_URL="${1:-}"
ADMIN_PASSWORD="${2:-}"

# ── Resolve URL ──────────────────────────────────────────────────────────────
if [[ -z "$NEXUS_URL" ]]; then
  NEXUS_URL=$(cd "$(dirname "$0")/../infra" && terraform output -raw nexus_url 2>/dev/null || true)
fi
if [[ -z "$NEXUS_URL" ]]; then
  echo "ERROR: Nexus URL not found. Pass it as first argument or run infra/ apply first." >&2
  exit 1
fi
NEXUS_URL="${NEXUS_URL%/}"

if [[ -z "$ADMIN_PASSWORD" ]]; then
  read -r -s -p "Enter admin password: " ADMIN_PASSWORD
  echo ""
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
pass=0
fail=0
GREEN='\033[0;32m'
RED='\033[0;31m'
GRAY='\033[0;90m'
RESET='\033[0m'

check_http() {
  local label="$1" url="$2"
  shift 2
  local expect=()
  # Collect expected HTTP codes (args before '--')
  while [[ $# -gt 0 && "$1" != '--' ]]; do
    expect+=("$1"); shift
  done
  [[ $# -gt 0 ]] && shift  # consume '--'
  # $@ now holds optional extra curl args; "$@" expands to nothing when empty
  # (unlike "${arr[@]}" which triggers unbound variable on bash 3.2 with set -u)
  [[ ${#expect[@]} -eq 0 ]] && expect=("200")

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$@" "$url")

  local ok=false
  for e in "${expect[@]}"; do [[ "$code" == "$e" ]] && ok=true && break; done

  if $ok; then
    printf "  ${GREEN}[PASS]${RESET} %s\n" "$label"
    pass=$((pass+1))
  else
    local want; want=$(IFS='/'; echo "${expect[*]}")
    printf "  ${RED}[FAIL]${RESET} %s  (HTTP %s, expected %s)\n" "$label" "$code" "$want"
    printf "         ${GRAY}%s${RESET}\n" "$url"
    fail=$((fail+1))
  fi
}

check_body() {
  local label="$1" url="$2" contains="$3"
  shift 3
  local body
  body=$(curl -sf "$@" "$url" 2>/dev/null || true)
  if echo "$body" | grep -q "$contains"; then
    printf "  ${GREEN}[PASS]${RESET} %s\n" "$label"
    pass=$((pass+1))
  else
    printf "  ${RED}[FAIL]${RESET} %s  (expected '%s' in response)\n" "$label" "$contains"
    fail=$((fail+1))
  fi
}

sep() { printf '%0.s─' {1..60}; echo ""; }

# ── Anonymous checks ──────────────────────────────────────────────────────────
echo ""
echo "Nexus Phase 2 smoke test  $NEXUS_URL"
sep

echo ""
echo "Anonymous access"
check_http 'PyPI group index readable'              "$NEXUS_URL/repository/pypi-group/simple/"
check_http 'Allowlisted package accessible (numpy)' "$NEXUS_URL/repository/pypi-group/simple/numpy/"
check_http 'Blocked package denied (flask)'         "$NEXUS_URL/repository/pypi-group/simple/flask/" 403 404
check_http 'CRAN PACKAGES index readable'           "$NEXUS_URL/repository/r-group/src/contrib/PACKAGES.gz"
check_http 'Anonymous write rejected (pypi-hosted)' "$NEXUS_URL/repository/pypi-hosted/" 401 -- -X POST

# ── pip client tests ─────────────────────────────────────────────────────────
echo ""
echo "pip client"

check_pip() {
  local label="$1" pkg="$2" expect_pass="$3"
  if ! command -v pip &>/dev/null; then
    printf "  [SKIP] %s  (pip not found)\n" "$label"
    return
  fi
  local host="${NEXUS_URL#https://}"; host="${host#http://}"; host="${host%%/*}"
  local out
  out=$(pip index versions "$pkg" \
    --index-url "$NEXUS_URL/repository/pypi-group/simple/" \
    --trusted-host "$host" \
    2>&1 || true)
  if $expect_pass; then
    if echo "$out" | grep -qi "Available versions\|${pkg}"; then
      printf "  ${GREEN}[PASS]${RESET} %s\n" "$label"
      pass=$((pass+1))
    else
      printf "  ${RED}[FAIL]${RESET} %s  (expected pip to find package in index)\n" "$label"
      fail=$((fail+1))
    fi
  else
    if echo "$out" | grep -qi "could not find\|no matching\|not find\|error\|403\|404"; then
      printf "  ${GREEN}[PASS]${RESET} %s  (correctly blocked)\n" "$label"
      pass=$((pass+1))
    else
      printf "  ${RED}[FAIL]${RESET} %s  (expected block, but pip found the package)\n" "$label"
      fail=$((fail+1))
    fi
  fi
}

check_pip 'pip install numpy (allowlisted)'  numpy true
check_pip 'pip install flask  (blocked)'     flask  false

# ── Admin password checks ─────────────────────────────────────────────────────
echo ""
echo "Admin credentials"
check_http 'Admin password accepted'              "$NEXUS_URL/service/rest/v1/security/users" 200 -- -u "admin:$ADMIN_PASSWORD"
check_http 'Default password (admin123) rejected' "$NEXUS_URL/service/rest/v1/security/users" 401 -- -u 'admin:admin123'

# ── Repository existence ──────────────────────────────────────────────────────
echo ""
echo "Repositories"
for repo in pypi-hosted pypi-pypi.org pypi-group r-hosted r-cran.r-project.org r-group; do
  check_body "Repo '$repo' exists" "$NEXUS_URL/service/rest/v1/repositories" "$repo" -u "admin:$ADMIN_PASSWORD"
done

# ── Routing rules ─────────────────────────────────────────────────────────────
echo ""
echo "Routing rules"
check_http 'pypi-allowlist exists'   "$NEXUS_URL/service/rest/v1/routing-rules/pypi-allowlist"   200 -- -u "admin:$ADMIN_PASSWORD"
check_http 'r-cran-allowlist exists' "$NEXUS_URL/service/rest/v1/routing-rules/r-cran-allowlist" 200 -- -u "admin:$ADMIN_PASSWORD"

# ── Anonymous user roles ──────────────────────────────────────────────────────
echo ""
echo "Anonymous user roles"
check_body 'anonymous user has pypi-anonymous-reader' "$NEXUS_URL/service/rest/v1/security/users?userId=anonymous" 'pypi-anonymous-reader' -u "admin:$ADMIN_PASSWORD"
check_body 'anonymous user has r-anonymous-reader'    "$NEXUS_URL/service/rest/v1/security/users?userId=anonymous" 'r-anonymous-reader'    -u "admin:$ADMIN_PASSWORD"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
sep
if [[ $fail -eq 0 ]]; then
  printf "${GREEN}%d passed, %d failed${RESET}\n\n" "$pass" "$fail"
else
  printf "${RED}%d passed, %d failed${RESET}\n\n" "$pass" "$fail"
  exit 1
fi
