###############################################################################
# Bootstrap — configure Nexus OSS via its REST API
#
#   1.  Wait for /service/rest/v1/status to return HTTP 200 (up to 2 min).
#       If unreachable after 2 min (VNet-private deployment), bootstrap is
#       skipped — config persists in the Azure Files share.
#   2.  Set the admin password (idempotent across re-runs).
#   3.  Enable global anonymous access.
#
#   Python (PyPI proxy)
#   4.  Create the PyPI allowlist routing rule (pypi-allowlist).
#       Categories: toolchain · core data · distributed · visualisation ·
#       ML · MLOps · explainability · data quality · I/O · Jupyter · runtime.
#   5.  Create the hosted repo   (pypi-hosted).
#   6.  Create the proxy repo    (pypi-pypi.org  → https://pypi.org, routing rule applied).
#   7.  Create the group repo    (pypi-group = hosted + proxy, single pip URL).
#   8.  Create / update cleanup policy (pypi-proxy-cleanup, 90-day last-downloaded).
#   9.  Create / update two roles:
#         pypi-anonymous-reader      browse + read on pypi-group
#         pypi-authenticated-deployer browse + read on pypi-group + add on pypi-hosted
#
#   R (CRAN proxy)
#   10. Create the CRAN allowlist routing rule (r-cran-allowlist).
#       Categories: toolchain · tidyverse plumbing · data wrangling ·
#       I/O & formats · visualisation · string matching.
#       Each package matches 3 paths: source tarball, Windows binary, macOS binary.
#   11. Create the hosted repo   (r-hosted).
#   12. Create the proxy repo    (r-cran.r-project.org → https://cran.r-project.org).
#   13. Create the group repo    (r-group = hosted + proxy).
#   14. Create / update cleanup policy (r-proxy-cleanup, 90-day last-downloaded).
#   15. Create / update two roles:
#         r-anonymous-reader      browse + read on r-group
#         r-authenticated-deployer browse + read on r-group + add on r-hosted
#   16. Lock the anonymous user to both pypi-anonymous-reader and r-anonymous-reader.
#
# Supply-chain protection
#   Routing rules in ALLOW mode mean proxies only serve packages whose path
#   matches the allowlist.  Everything else gets a 404; hosted repos are
#   unaffected (admins control them).
#
# Prerequisites on the Terraform machine: bash, curl, jq
###############################################################################

resource "time_sleep" "wait_for_container_start" {
  depends_on      = [azurerm_container_group.nexus]
  create_duration = "2m"
}

resource "null_resource" "configure_nexus" {
  depends_on = [time_sleep.wait_for_container_start]

  triggers = {
    # Do NOT include container_id here.
    # All Nexus config (repos, roles, routing rules) is persisted in the Azure
    # Files share and survives container replacement (e.g. moving to VNet mode).
    # Re-run is only needed when the password or allowlist config actually changes.
    admin_password_sha256 = sha256(var.admin_password)
    allowlist_version     = "6"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
      set -euo pipefail

      NEXUS="${local.nexus_api_url}"
      ADMIN_PASS="${var.admin_password}"

      # -----------------------------------------------------------------------
      # 1. Wait for Nexus (up to 2 minutes)
      #
      # If Nexus is unreachable after 2 minutes we assume this is a VNet-
      # integrated deployment where the private IP is not reachable from the
      # Terraform host.  All configuration persists in the Azure Files share
      # across container replacements, so bootstrap can safely be skipped.
      # -----------------------------------------------------------------------
      echo "==> Waiting for Nexus at ${local.nexus_base_url} ..."
      MAX=12; N=0
      until curl -sf --connect-timeout 5 -o /dev/null "$NEXUS/status"; do
        N=$((N+1))
        if [ $N -ge $MAX ]; then
          echo ""
          echo "============================================================"
          echo " Nexus unreachable after 2 minutes."
          echo " This is expected when ACI is VNet-integrated (private IP)."
          echo " Existing configuration persists in the Azure Files share."
          echo " Bootstrap skipped — no action required."
          echo "============================================================"
          exit 0
        fi
        echo "    ($N/$MAX) ..."
        sleep 10
      done
      echo "    Nexus is up!"

      # -----------------------------------------------------------------------
      # 2. Set / confirm admin password
      # -----------------------------------------------------------------------
      echo "==> Checking admin credentials ..."
      AUTH_OK=$(curl -s -o /dev/null -w "%%{http_code}" \
                  -u "admin:$ADMIN_PASS" "$NEXUS/security/users")
      if [ "$AUTH_OK" = "200" ]; then
        echo "    Password already correct — skipping change."
      else
        HTTP=$(curl -s -o /dev/null -w "%%{http_code}" \
                 -u "admin:admin123" \
                 -X PUT "$NEXUS/security/users/admin/change-password" \
                 -H "Content-Type: text/plain" \
                 -d "$ADMIN_PASS")
        [ "$HTTP" = "204" ] || [ "$HTTP" = "200" ] \
          || { echo "ERROR: change-password returned HTTP $HTTP"; exit 1; }
        echo "    Password set."
      fi

      # -----------------------------------------------------------------------
      # Helpers
      # -----------------------------------------------------------------------
      nexus_put() {
        local path="$1" body="$2" http
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" -X PUT "$NEXUS/$path" \
                 -H "Content-Type: application/json" -d "$body")
        echo "    PUT $path -> $http"
        [ "$http" = "200" ] || [ "$http" = "204" ] || { cat /tmp/nx_resp.txt; echo; }
      }

      # Create repo if it doesn't exist (checks by name, repo_type = hosted|proxy|group, format = pypi|r|…)
      nexus_create_repo() {
        local repo_type="$1" repo_name="$2" body="$3" format="$${4:-pypi}"
        EXISTS=$(curl -s -u "admin:$ADMIN_PASS" "$NEXUS/repositories" \
                   | jq -r --arg n "$repo_name" '.[] | select(.name==$n) | .name')
        if [ -n "$EXISTS" ]; then
          echo "    '$repo_name' already exists — skipping."
          return 0
        fi
        local http
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" \
                 -X POST "$NEXUS/repositories/$format/$repo_type" \
                 -H "Content-Type: application/json" -d "$body")
        echo "    Created $format/$repo_type '$repo_name' -> $http"
        [ "$http" = "201" ] || [ "$http" = "200" ] || { cat /tmp/nx_resp.txt; echo; }
      }

      # Upsert routing rule — PUT (update) if it already exists, POST to create if not.
      # This ensures the matchers stay in sync with the Terraform config on every apply.
      nexus_upsert_routing_rule() {
        local rule_name="$1" body="$2"
        EXISTS=$(curl -s -o /dev/null -w "%%{http_code}" \
                   -u "admin:$ADMIN_PASS" "$NEXUS/routing-rules/$rule_name")
        if [ "$EXISTS" = "200" ]; then
          local http
          http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                   -u "admin:$ADMIN_PASS" \
                   -X PUT "$NEXUS/routing-rules/$rule_name" \
                   -H "Content-Type: application/json" -d "$body")
          echo "    Updated routing rule '$rule_name' -> $http"
          [ "$http" = "200" ] || [ "$http" = "204" ] || { cat /tmp/nx_resp.txt; echo; }
        else
          local http
          http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                   -u "admin:$ADMIN_PASS" \
                   -X POST "$NEXUS/routing-rules" \
                   -H "Content-Type: application/json" -d "$body")
          echo "    Created routing rule '$rule_name' -> $http"
          [ "$http" = "200" ] || [ "$http" = "201" ] || { cat /tmp/nx_resp.txt; echo; }
        fi
      }

      # Create role if missing, update (PUT) if it already exists so privileges stay current
      nexus_upsert_role() {
        local role_id="$1" body="$2"
        EXISTS=$(curl -s -o /dev/null -w "%%{http_code}" \
                   -u "admin:$ADMIN_PASS" "$NEXUS/security/roles/$role_id")
        if [ "$EXISTS" = "200" ]; then
          local http
          http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                   -u "admin:$ADMIN_PASS" \
                   -X PUT "$NEXUS/security/roles/$role_id" \
                   -H "Content-Type: application/json" -d "$body")
          echo "    Updated role '$role_id' -> $http"
          [ "$http" = "200" ] || [ "$http" = "204" ] || { cat /tmp/nx_resp.txt; echo; }
        else
          local http
          http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                   -u "admin:$ADMIN_PASS" \
                   -X POST "$NEXUS/security/roles" \
                   -H "Content-Type: application/json" -d "$body")
          echo "    Created role '$role_id' -> $http"
          [ "$http" = "200" ] || [ "$http" = "201" ] || { cat /tmp/nx_resp.txt; echo; }
        fi
      }

      # -----------------------------------------------------------------------
      # 3. Enable anonymous access
      # -----------------------------------------------------------------------
      echo "==> Enabling anonymous access ..."
      nexus_put "security/anonymous" \
        '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}'

      # -----------------------------------------------------------------------
      # 4. Create the package allowlist routing rule
      #
      #    Mode ALLOW: only paths matching at least one matcher are served by
      #    the proxy.  Anything not on the list gets a 404 from the proxy.
      #    The hosted repo is not subject to this rule.
      # -----------------------------------------------------------------------
      echo "==> Upserting pypi-allowlist routing rule ..."
      # Each package needs TWO matchers:
      #   ^/simple/{name}   — index lookup  (pip resolves which file to download)
      #   ^/packages/{name} — file download (Nexus serves the cached .whl / .tar.gz)
      # Without both, the index resolves fine but the actual download returns 404.
      nexus_upsert_routing_rule "pypi-allowlist" '{
        "name":        "pypi-allowlist",
        "description": "Supply-chain gate: only approved packages pass through the PyPI proxy",
        "mode":        "ALLOW",
        "matchers": [

          "^/simple/pip(/.*)?$",              "^/packages/pip(/.*)?$",
          "^/simple/setuptools(/.*)?$",       "^/packages/setuptools(/.*)?$",
          "^/simple/wheel(/.*)?$",            "^/packages/wheel(/.*)?$",
          "^/simple/twine(/.*)?$",            "^/packages/twine(/.*)?$",
          "^/simple/build(/.*)?$",            "^/packages/build(/.*)?$",
          "^/simple/poetry(/.*)?$",           "^/packages/poetry(/.*)?$",
          "^/simple/pytest(/.*)?$",           "^/packages/pytest(/.*)?$",

          "^/simple/numpy(/.*)?$",            "^/packages/numpy(/.*)?$",
          "^/simple/pandas(/.*)?$",           "^/packages/pandas(/.*)?$",
          "^/simple/scipy(/.*)?$",            "^/packages/scipy(/.*)?$",
          "^/simple/polars(/.*)?$",           "^/packages/polars(/.*)?$",
          "^/simple/pyarrow(/.*)?$",          "^/packages/pyarrow(/.*)?$",

          "^/simple/dask(/.*)?$",             "^/packages/dask(/.*)?$",
          "^/simple/pyspark(/.*)?$",          "^/packages/pyspark(/.*)?$",

          "^/simple/matplotlib(/.*)?$",       "^/packages/matplotlib(/.*)?$",
          "^/simple/seaborn(/.*)?$",          "^/packages/seaborn(/.*)?$",
          "^/simple/plotly(/.*)?$",           "^/packages/plotly(/.*)?$",
          "^/simple/bokeh(/.*)?$",            "^/packages/bokeh(/.*)?$",
          "^/simple/altair(/.*)?$",           "^/packages/altair(/.*)?$",
          "^/simple/kaleido(/.*)?$",          "^/packages/kaleido(/.*)?$",
          "^/simple/missingno(/.*)?$",        "^/packages/missingno(/.*)?$",

          "^/simple/scikit-learn(/.*)?$",     "^/packages/scikit-learn(/.*)?$",
          "^/simple/xgboost(/.*)?$",          "^/packages/xgboost(/.*)?$",
          "^/simple/lightgbm(/.*)?$",         "^/packages/lightgbm(/.*)?$",
          "^/simple/statsmodels(/.*)?$",      "^/packages/statsmodels(/.*)?$",
          "^/simple/lifelines(/.*)?$",        "^/packages/lifelines(/.*)?$",
          "^/simple/pingouin(/.*)?$",         "^/packages/pingouin(/.*)?$",

          "^/simple/mlflow(/.*)?$",           "^/packages/mlflow(/.*)?$",

          "^/simple/shap(/.*)?$",             "^/packages/shap(/.*)?$",
          "^/simple/lime(/.*)?$",             "^/packages/lime(/.*)?$",
          "^/simple/eli5(/.*)?$",             "^/packages/eli5(/.*)?$",

          "^/simple/pandera(/.*)?$",          "^/packages/pandera(/.*)?$",
          "^/simple/great-expectations(/.*)?$","^/packages/great-expectations(/.*)?$",

          "^/simple/openpyxl(/.*)?$",         "^/packages/openpyxl(/.*)?$",
          "^/simple/xlrd(/.*)?$",             "^/packages/xlrd(/.*)?$",
          "^/simple/xlsxwriter(/.*)?$",       "^/packages/xlsxwriter(/.*)?$",
          "^/simple/fastparquet(/.*)?$",      "^/packages/fastparquet(/.*)?$",
          "^/simple/sqlalchemy(/.*)?$",       "^/packages/sqlalchemy(/.*)?$",
          "^/simple/psycopg2-binary(/.*)?$",  "^/packages/psycopg2-binary(/.*)?$",
          "^/simple/pymysql(/.*)?$",          "^/packages/pymysql(/.*)?$",
          "^/simple/pyodbc(/.*)?$",           "^/packages/pyodbc(/.*)?$",

          "^/simple/jupyter(/.*)?$",          "^/packages/jupyter(/.*)?$",
          "^/simple/jupyterlab(/.*)?$",       "^/packages/jupyterlab(/.*)?$",
          "^/simple/ipython(/.*)?$",          "^/packages/ipython(/.*)?$",
          "^/simple/ipykernel(/.*)?$",        "^/packages/ipykernel(/.*)?$",
          "^/simple/notebook(/.*)?$",         "^/packages/notebook(/.*)?$",
          "^/simple/nbformat(/.*)?$",         "^/packages/nbformat(/.*)?$",
          "^/simple/nbconvert(/.*)?$",        "^/packages/nbconvert(/.*)?$",
          "^/simple/ipywidgets(/.*)?$",       "^/packages/ipywidgets(/.*)?$",
          "^/simple/widgetsnbextension(/.*)?$","^/packages/widgetsnbextension(/.*)?$",

          "^/simple/joblib(/.*)?$",           "^/packages/joblib(/.*)?$",
          "^/simple/numba(/.*)?$",            "^/packages/numba(/.*)?$",
          "^/simple/tqdm(/.*)?$",             "^/packages/tqdm(/.*)?$",
          "^/simple/requests(/.*)?$",         "^/packages/requests(/.*)?$",
          "^/simple/httpx(/.*)?$",            "^/packages/httpx(/.*)?$",
          "^/simple/aiohttp(/.*)?$",          "^/packages/aiohttp(/.*)?$",
          "^/simple/python-dateutil(/.*)?$",  "^/packages/python-dateutil(/.*)?$",
          "^/simple/pytz(/.*)?$",             "^/packages/pytz(/.*)?$",
          "^/simple/tzdata(/.*)?$",           "^/packages/tzdata(/.*)?$",
          "^/simple/six(/.*)?$",              "^/packages/six(/.*)?$",
          "^/simple/certifi(/.*)?$",          "^/packages/certifi(/.*)?$",
          "^/simple/charset-normalizer(/.*)?$","^/packages/charset-normalizer(/.*)?$",
          "^/simple/idna(/.*)?$",             "^/packages/idna(/.*)?$",
          "^/simple/urllib3(/.*)?$",          "^/packages/urllib3(/.*)?$",
          "^/simple/packaging(/.*)?$",        "^/packages/packaging(/.*)?$",
          "^/simple/click(/.*)?$",            "^/packages/click(/.*)?$",
          "^/simple/pydantic(/.*)?$",         "^/packages/pydantic(/.*)?$",
          "^/simple/pydantic-core(/.*)?$",    "^/packages/pydantic-core(/.*)?$",
          "^/simple/typing-extensions(/.*)?$","^/packages/typing-extensions(/.*)?$",
          "^/simple/attrs(/.*)?$",            "^/packages/attrs(/.*)?$",
          "^/simple/annotated-types(/.*)?$",  "^/packages/annotated-types(/.*)?$"

        ]
      }'

      # -----------------------------------------------------------------------
      # 5. Create the hosted repo  (curated/internal packages, admin-uploaded)
      # -----------------------------------------------------------------------
      echo "==> Creating pypi-hosted ..."
      nexus_create_repo "hosted" "pypi-hosted" '{
        "name":    "pypi-hosted",
        "online":  true,
        "storage": {
          "blobStoreName":               "default",
          "strictContentTypeValidation": true,
          "writePolicy":                 "allow"
        }
      }'

      # -----------------------------------------------------------------------
      # 6. Create the proxy repo  (fetches from PyPI, filtered by routing rule)
      # -----------------------------------------------------------------------
      echo "==> Creating pypi-pypi.org proxy ..."
      nexus_create_repo "proxy" "pypi-pypi.org" '{
        "name":    "pypi-pypi.org",
        "online":  true,
        "storage": {
          "blobStoreName":               "default",
          "strictContentTypeValidation": true
        },
        "proxy": {
          "remoteUrl":      "https://pypi.org",
          "contentMaxAge":  1440,
          "metadataMaxAge": 1440
        },
        "negativeCache": {
          "enabled":    true,
          "timeToLive": 1440
        },
        "httpClient": {
          "blocked":   false,
          "autoBlock": true
        },
        "routingRuleName": "pypi-allowlist"
      }'

      # -----------------------------------------------------------------------
      # 7. Create the group repo  (single pip URL: hosted first, then proxy)
      #    Hosted takes priority so internal packages shadow PyPI names
      #    (prevents dependency-confusion attacks on private package names).
      # -----------------------------------------------------------------------
      echo "==> Creating pypi-group ..."
      nexus_create_repo "group" "pypi-group" '{
        "name":    "pypi-group",
        "online":  true,
        "storage": {
          "blobStoreName":               "default",
          "strictContentTypeValidation": true
        },
        "group": {
          "memberNames": ["pypi-hosted", "pypi-pypi.org"]
        }
      }'

      # Nexus generates repository privileges asynchronously — wait for all three repos
      echo "    Waiting for Nexus to generate privileges ..."
      sleep 10

      # -----------------------------------------------------------------------
      # 8. Cleanup policy — remove proxy-cached assets not downloaded in 90 days
      #
      #    Without a cleanup policy the Azure Files share slowly fills up with
      #    every .whl and .tar.gz ever fetched via the proxy.
      #    This policy marks stale cached files for deletion; the Nexus scheduler
      #    runs the actual purge nightly by default.
      # -----------------------------------------------------------------------
      echo "==> Upserting pypi-proxy-cleanup policy ..."
      POLICY_EXISTS=$(curl -s -u "admin:$ADMIN_PASS" "$NEXUS/cleanup-policies" \
                        | jq -r '.[] | select(.name=="pypi-proxy-cleanup") | .name')
      CLEANUP_BODY='{
        "name":   "pypi-proxy-cleanup",
        "format": "pypi",
        "notes":  "Remove proxy-cached assets not downloaded in 90 days",
        "criteria": {
          "lastDownloaded": 90
        }
      }'
      if [ -n "$POLICY_EXISTS" ]; then
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" \
                 -X PUT "$NEXUS/cleanup-policies/pypi-proxy-cleanup" \
                 -H "Content-Type: application/json" -d "$CLEANUP_BODY")
        echo "    Updated cleanup policy -> $http"
        [ "$http" = "200" ] || [ "$http" = "204" ] || { cat /tmp/nx_resp.txt; echo; }
      else
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" \
                 -X POST "$NEXUS/cleanup-policies" \
                 -H "Content-Type: application/json" -d "$CLEANUP_BODY")
        echo "    Created cleanup policy -> $http"
        [ "$http" = "200" ] || [ "$http" = "201" ] || { cat /tmp/nx_resp.txt; echo; }
      fi

      echo "==> Associating cleanup policy with pypi-pypi.org ..."
      PROXY_CONFIG=$(curl -s -u "admin:$ADMIN_PASS" \
                       "$NEXUS/repositories/pypi/proxy/pypi-pypi.org")
      if [ -n "$PROXY_CONFIG" ] && echo "$PROXY_CONFIG" | jq -e '.name' > /dev/null 2>&1; then
        UPDATED=$(echo "$PROXY_CONFIG" \
                    | jq '.cleanup = {"policyNames": ["pypi-proxy-cleanup"]}')
        nexus_put "repositories/pypi/proxy/pypi-pypi.org" "$UPDATED"
      else
        echo "    pypi-pypi.org not found — cleanup association skipped (will apply on next run)."
      fi

      # -----------------------------------------------------------------------
      # 9. Roles
      #    Anonymous readers use pypi-group (so they get the routing-rule filter).
      #    Authenticated deployers get pypi-group for reads + pypi-hosted for upload.
      # -----------------------------------------------------------------------
      echo "==> Upserting roles ..."

      # Anonymous: browse + read through the group (proxy gated by routing rule)
      nexus_upsert_role "pypi-anonymous-reader" '{
        "id":          "pypi-anonymous-reader",
        "name":        "PyPI Anonymous Reader",
        "description": "Browse and download allowlisted packages via pypi-group (no upload)",
        "privileges": [
          "nx-repository-view-pypi-pypi-group-browse",
          "nx-repository-view-pypi-pypi-group-read"
        ],
        "roles": []
      }'

      # Authenticated: browse + read through group, deploy to hosted
      nexus_upsert_role "pypi-authenticated-deployer" '{
        "id":          "pypi-authenticated-deployer",
        "name":        "PyPI Authenticated Deployer",
        "description": "Browse/download via pypi-group; upload new packages to pypi-hosted",
        "privileges": [
          "nx-repository-view-pypi-pypi-group-browse",
          "nx-repository-view-pypi-pypi-group-read",
          "nx-repository-view-pypi-pypi-hosted-browse",
          "nx-repository-view-pypi-pypi-hosted-read",
          "nx-repository-view-pypi-pypi-hosted-add"
        ],
        "roles": []
      }'

      # -----------------------------------------------------------------------
      # -----------------------------------------------------------------------
      # R (CRAN proxy)
      # -----------------------------------------------------------------------
      # -----------------------------------------------------------------------

      # -----------------------------------------------------------------------
      # 10. Create the CRAN allowlist routing rule
      #
      #     CRAN paths differ from PyPI — each package needs THREE matchers:
      #       ^/src/contrib/{name}_          — source tarball
      #       ^/bin/windows/contrib/…/{name}_ — Windows binary
      #       ^/bin/macosx/…/{name}_          — macOS binary
      #
      #     Four global matchers are also required so R can fetch the package
      #     index (PACKAGES files) before attempting any download.
      # -----------------------------------------------------------------------
      echo "==> Upserting r-cran-allowlist routing rule ..."
      nexus_upsert_routing_rule "r-cran-allowlist" '{
        "name":        "r-cran-allowlist",
        "description": "Supply-chain gate: only approved R packages pass through the CRAN proxy",
        "mode":        "ALLOW",
        "matchers": [

          "^/src/contrib/PACKAGES",
          "^/src/contrib/Meta/",
          "^/bin/windows/contrib/[^/]+/PACKAGES",
          "^/bin/macosx/[^/]+/contrib/[^/]+/PACKAGES",

          "^/src/contrib/rlang_",              "^/bin/windows/contrib/[^/]+/rlang_",              "^/bin/macosx/[^/]+/contrib/[^/]+/rlang_",
          "^/src/contrib/vctrs_",              "^/bin/windows/contrib/[^/]+/vctrs_",              "^/bin/macosx/[^/]+/contrib/[^/]+/vctrs_",
          "^/src/contrib/lifecycle_",          "^/bin/windows/contrib/[^/]+/lifecycle_",          "^/bin/macosx/[^/]+/contrib/[^/]+/lifecycle_",
          "^/src/contrib/cli_",                "^/bin/windows/contrib/[^/]+/cli_",                "^/bin/macosx/[^/]+/contrib/[^/]+/cli_",
          "^/src/contrib/glue_",               "^/bin/windows/contrib/[^/]+/glue_",               "^/bin/macosx/[^/]+/contrib/[^/]+/glue_",
          "^/src/contrib/magrittr_",           "^/bin/windows/contrib/[^/]+/magrittr_",           "^/bin/macosx/[^/]+/contrib/[^/]+/magrittr_",
          "^/src/contrib/generics_",           "^/bin/windows/contrib/[^/]+/generics_",           "^/bin/macosx/[^/]+/contrib/[^/]+/generics_",
          "^/src/contrib/R6_",                 "^/bin/windows/contrib/[^/]+/R6_",                 "^/bin/macosx/[^/]+/contrib/[^/]+/R6_",
          "^/src/contrib/Rcpp_",               "^/bin/windows/contrib/[^/]+/Rcpp_",               "^/bin/macosx/[^/]+/contrib/[^/]+/Rcpp_",
          "^/src/contrib/withr_",              "^/bin/windows/contrib/[^/]+/withr_",              "^/bin/macosx/[^/]+/contrib/[^/]+/withr_",
          "^/src/contrib/pkgconfig_",          "^/bin/windows/contrib/[^/]+/pkgconfig_",          "^/bin/macosx/[^/]+/contrib/[^/]+/pkgconfig_",
          "^/src/contrib/ellipsis_",           "^/bin/windows/contrib/[^/]+/ellipsis_",           "^/bin/macosx/[^/]+/contrib/[^/]+/ellipsis_",

          "^/src/contrib/tibble_",             "^/bin/windows/contrib/[^/]+/tibble_",             "^/bin/macosx/[^/]+/contrib/[^/]+/tibble_",
          "^/src/contrib/purrr_",              "^/bin/windows/contrib/[^/]+/purrr_",              "^/bin/macosx/[^/]+/contrib/[^/]+/purrr_",
          "^/src/contrib/readr_",              "^/bin/windows/contrib/[^/]+/readr_",              "^/bin/macosx/[^/]+/contrib/[^/]+/readr_",
          "^/src/contrib/forcats_",            "^/bin/windows/contrib/[^/]+/forcats_",            "^/bin/macosx/[^/]+/contrib/[^/]+/forcats_",
          "^/src/contrib/hms_",                "^/bin/windows/contrib/[^/]+/hms_",                "^/bin/macosx/[^/]+/contrib/[^/]+/hms_",
          "^/src/contrib/vroom_",              "^/bin/windows/contrib/[^/]+/vroom_",              "^/bin/macosx/[^/]+/contrib/[^/]+/vroom_",
          "^/src/contrib/tidyselect_",         "^/bin/windows/contrib/[^/]+/tidyselect_",         "^/bin/macosx/[^/]+/contrib/[^/]+/tidyselect_",
          "^/src/contrib/pillar_",             "^/bin/windows/contrib/[^/]+/pillar_",             "^/bin/macosx/[^/]+/contrib/[^/]+/pillar_",
          "^/src/contrib/fansi_",              "^/bin/windows/contrib/[^/]+/fansi_",              "^/bin/macosx/[^/]+/contrib/[^/]+/fansi_",
          "^/src/contrib/utf8_",               "^/bin/windows/contrib/[^/]+/utf8_",               "^/bin/macosx/[^/]+/contrib/[^/]+/utf8_",
          "^/src/contrib/crayon_",             "^/bin/windows/contrib/[^/]+/crayon_",             "^/bin/macosx/[^/]+/contrib/[^/]+/crayon_",
          "^/src/contrib/bit64_",              "^/bin/windows/contrib/[^/]+/bit64_",              "^/bin/macosx/[^/]+/contrib/[^/]+/bit64_",
          "^/src/contrib/bit_",                "^/bin/windows/contrib/[^/]+/bit_",                "^/bin/macosx/[^/]+/contrib/[^/]+/bit_",

          "^/src/contrib/tidyverse_",          "^/bin/windows/contrib/[^/]+/tidyverse_",          "^/bin/macosx/[^/]+/contrib/[^/]+/tidyverse_",
          "^/src/contrib/dplyr_",              "^/bin/windows/contrib/[^/]+/dplyr_",              "^/bin/macosx/[^/]+/contrib/[^/]+/dplyr_",
          "^/src/contrib/tidyr_",              "^/bin/windows/contrib/[^/]+/tidyr_",              "^/bin/macosx/[^/]+/contrib/[^/]+/tidyr_",
          "^/src/contrib/stringr_",            "^/bin/windows/contrib/[^/]+/stringr_",            "^/bin/macosx/[^/]+/contrib/[^/]+/stringr_",
          "^/src/contrib/stringi_",            "^/bin/windows/contrib/[^/]+/stringi_",            "^/bin/macosx/[^/]+/contrib/[^/]+/stringi_",
          "^/src/contrib/data\\.table_",       "^/bin/windows/contrib/[^/]+/data\\.table_",       "^/bin/macosx/[^/]+/contrib/[^/]+/data\\.table_",
          "^/src/contrib/lubridate_",          "^/bin/windows/contrib/[^/]+/lubridate_",          "^/bin/macosx/[^/]+/contrib/[^/]+/lubridate_",
          "^/src/contrib/broom_",              "^/bin/windows/contrib/[^/]+/broom_",              "^/bin/macosx/[^/]+/contrib/[^/]+/broom_",
          "^/src/contrib/modelr_",             "^/bin/windows/contrib/[^/]+/modelr_",             "^/bin/macosx/[^/]+/contrib/[^/]+/modelr_",

          "^/src/contrib/haven_",              "^/bin/windows/contrib/[^/]+/haven_",              "^/bin/macosx/[^/]+/contrib/[^/]+/haven_",
          "^/src/contrib/readxl_",             "^/bin/windows/contrib/[^/]+/readxl_",             "^/bin/macosx/[^/]+/contrib/[^/]+/readxl_",
          "^/src/contrib/openxlsx_",           "^/bin/windows/contrib/[^/]+/openxlsx_",           "^/bin/macosx/[^/]+/contrib/[^/]+/openxlsx_",
          "^/src/contrib/rio_",                "^/bin/windows/contrib/[^/]+/rio_",                "^/bin/macosx/[^/]+/contrib/[^/]+/rio_",
          "^/src/contrib/foreign_",            "^/bin/windows/contrib/[^/]+/foreign_",            "^/bin/macosx/[^/]+/contrib/[^/]+/foreign_",
          "^/src/contrib/cellranger_",         "^/bin/windows/contrib/[^/]+/cellranger_",         "^/bin/macosx/[^/]+/contrib/[^/]+/cellranger_",
          "^/src/contrib/zip_",                "^/bin/windows/contrib/[^/]+/zip_",                "^/bin/macosx/[^/]+/contrib/[^/]+/zip_",
          "^/src/contrib/jsonlite_",           "^/bin/windows/contrib/[^/]+/jsonlite_",           "^/bin/macosx/[^/]+/contrib/[^/]+/jsonlite_",
          "^/src/contrib/curl_",               "^/bin/windows/contrib/[^/]+/curl_",               "^/bin/macosx/[^/]+/contrib/[^/]+/curl_",
          "^/src/contrib/httr_",               "^/bin/windows/contrib/[^/]+/httr_",               "^/bin/macosx/[^/]+/contrib/[^/]+/httr_",

          "^/src/contrib/ggplot2_",            "^/bin/windows/contrib/[^/]+/ggplot2_",            "^/bin/macosx/[^/]+/contrib/[^/]+/ggplot2_",
          "^/src/contrib/scales_",             "^/bin/windows/contrib/[^/]+/scales_",             "^/bin/macosx/[^/]+/contrib/[^/]+/scales_",
          "^/src/contrib/gtable_",             "^/bin/windows/contrib/[^/]+/gtable_",             "^/bin/macosx/[^/]+/contrib/[^/]+/gtable_",
          "^/src/contrib/isoband_",            "^/bin/windows/contrib/[^/]+/isoband_",            "^/bin/macosx/[^/]+/contrib/[^/]+/isoband_",
          "^/src/contrib/farver_",             "^/bin/windows/contrib/[^/]+/farver_",             "^/bin/macosx/[^/]+/contrib/[^/]+/farver_",
          "^/src/contrib/labeling_",           "^/bin/windows/contrib/[^/]+/labeling_",           "^/bin/macosx/[^/]+/contrib/[^/]+/labeling_",
          "^/src/contrib/munsell_",            "^/bin/windows/contrib/[^/]+/munsell_",            "^/bin/macosx/[^/]+/contrib/[^/]+/munsell_",
          "^/src/contrib/RColorBrewer_",       "^/bin/windows/contrib/[^/]+/RColorBrewer_",       "^/bin/macosx/[^/]+/contrib/[^/]+/RColorBrewer_",
          "^/src/contrib/viridisLite_",        "^/bin/windows/contrib/[^/]+/viridisLite_",        "^/bin/macosx/[^/]+/contrib/[^/]+/viridisLite_",
          "^/src/contrib/colorspace_",         "^/bin/windows/contrib/[^/]+/colorspace_",         "^/bin/macosx/[^/]+/contrib/[^/]+/colorspace_",
          "^/src/contrib/MASS_",               "^/bin/windows/contrib/[^/]+/MASS_",               "^/bin/macosx/[^/]+/contrib/[^/]+/MASS_",

          "^/src/contrib/fuzzyjoin_",          "^/bin/windows/contrib/[^/]+/fuzzyjoin_",          "^/bin/macosx/[^/]+/contrib/[^/]+/fuzzyjoin_",
          "^/src/contrib/stringdist_",         "^/bin/windows/contrib/[^/]+/stringdist_",         "^/bin/macosx/[^/]+/contrib/[^/]+/stringdist_"

        ]
      }'

      # -----------------------------------------------------------------------
      # 11. Create the R hosted repo  (curated/internal packages, admin-uploaded)
      # -----------------------------------------------------------------------
      echo "==> Creating r-hosted ..."
      nexus_create_repo "hosted" "r-hosted" '{
        "name":    "r-hosted",
        "online":  true,
        "storage": {
          "blobStoreName":               "default",
          "strictContentTypeValidation": true,
          "writePolicy":                 "allow"
        }
      }' "r"

      # -----------------------------------------------------------------------
      # 12. Create the R proxy repo  (fetches from CRAN, filtered by routing rule)
      # -----------------------------------------------------------------------
      echo "==> Creating r-cran.r-project.org proxy ..."
      nexus_create_repo "proxy" "r-cran.r-project.org" '{
        "name":    "r-cran.r-project.org",
        "online":  true,
        "storage": {
          "blobStoreName":               "default",
          "strictContentTypeValidation": true
        },
        "proxy": {
          "remoteUrl":      "https://cran.r-project.org",
          "contentMaxAge":  1440,
          "metadataMaxAge": 1440
        },
        "negativeCache": {
          "enabled":    true,
          "timeToLive": 1440
        },
        "httpClient": {
          "blocked":   false,
          "autoBlock": true
        },
        "routingRuleName": "r-cran-allowlist"
      }' "r"

      # -----------------------------------------------------------------------
      # 13. Create the R group repo  (single URL for install.packages())
      # -----------------------------------------------------------------------
      echo "==> Creating r-group ..."
      nexus_create_repo "group" "r-group" '{
        "name":    "r-group",
        "online":  true,
        "storage": {
          "blobStoreName":               "default",
          "strictContentTypeValidation": true
        },
        "group": {
          "memberNames": ["r-hosted", "r-cran.r-project.org"]
        }
      }' "r"

      echo "    Waiting for Nexus to generate R privileges ..."
      sleep 10

      # -----------------------------------------------------------------------
      # 14. R cleanup policy — remove proxy-cached packages not downloaded in 90 days
      # -----------------------------------------------------------------------
      echo "==> Upserting r-proxy-cleanup policy ..."
      R_POLICY_EXISTS=$(curl -s -u "admin:$ADMIN_PASS" "$NEXUS/cleanup-policies" \
                          | jq -r '.[] | select(.name=="r-proxy-cleanup") | .name')
      R_CLEANUP_BODY='{
        "name":   "r-proxy-cleanup",
        "format": "r",
        "notes":  "Remove proxy-cached R packages not downloaded in 90 days",
        "criteria": {
          "lastDownloaded": 90
        }
      }'
      if [ -n "$R_POLICY_EXISTS" ]; then
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" \
                 -X PUT "$NEXUS/cleanup-policies/r-proxy-cleanup" \
                 -H "Content-Type: application/json" -d "$R_CLEANUP_BODY")
        echo "    Updated R cleanup policy -> $http"
        [ "$http" = "200" ] || [ "$http" = "204" ] || { cat /tmp/nx_resp.txt; echo; }
      else
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" \
                 -X POST "$NEXUS/cleanup-policies" \
                 -H "Content-Type: application/json" -d "$R_CLEANUP_BODY")
        echo "    Created R cleanup policy -> $http"
        [ "$http" = "200" ] || [ "$http" = "201" ] || { cat /tmp/nx_resp.txt; echo; }
      fi

      echo "==> Associating R cleanup policy with r-cran.r-project.org ..."
      R_PROXY_CONFIG=$(curl -s -u "admin:$ADMIN_PASS" \
                         "$NEXUS/repositories/r/proxy/r-cran.r-project.org")
      if [ -n "$R_PROXY_CONFIG" ] && echo "$R_PROXY_CONFIG" | jq -e '.name' > /dev/null 2>&1; then
        R_UPDATED=$(echo "$R_PROXY_CONFIG" \
                      | jq '.cleanup = {"policyNames": ["r-proxy-cleanup"]}')
        nexus_put "repositories/r/proxy/r-cran.r-project.org" "$R_UPDATED"
      else
        echo "    r-cran.r-project.org not found — cleanup association skipped (will apply on next run)."
      fi

      # -----------------------------------------------------------------------
      # 15. R roles
      # -----------------------------------------------------------------------
      echo "==> Upserting R roles ..."

      nexus_upsert_role "r-anonymous-reader" '{
        "id":          "r-anonymous-reader",
        "name":        "R Anonymous Reader",
        "description": "Browse and download allowlisted R packages via r-group (no upload)",
        "privileges": [
          "nx-repository-view-r-r-group-browse",
          "nx-repository-view-r-r-group-read"
        ],
        "roles": []
      }'

      nexus_upsert_role "r-authenticated-deployer" '{
        "id":          "r-authenticated-deployer",
        "name":        "R Authenticated Deployer",
        "description": "Browse/download via r-group; upload new packages to r-hosted",
        "privileges": [
          "nx-repository-view-r-r-group-browse",
          "nx-repository-view-r-r-group-read",
          "nx-repository-view-r-r-hosted-browse",
          "nx-repository-view-r-r-hosted-read",
          "nx-repository-view-r-r-hosted-add"
        ],
        "roles": []
      }'

      # -----------------------------------------------------------------------
      # 16. Lock the anonymous user to pypi-anonymous-reader + r-anonymous-reader
      #     (Removes the default nx-anonymous role which allows unrestricted browse)
      # -----------------------------------------------------------------------
      echo "==> Assigning reader roles to the anonymous user ..."
      nexus_put "security/users/anonymous" '{
        "userId":        "anonymous",
        "firstName":     "Anonymous",
        "lastName":      "User",
        "emailAddress":  "anonymous@example.org",
        "source":        "default",
        "status":        "active",
        "readOnly":      false,
        "roles":         ["pypi-anonymous-reader", "r-anonymous-reader"],
        "externalRoles": []
      }'

      echo ""
      echo "============================================================"
      echo " Nexus OSS ready."
      echo " pip index : ${local.pypi_simple_url}"
      echo " pip upload: ${local.pypi_upload_url}"
      echo " R repo    : ${local.nexus_base_url}/repository/r-group/"
      echo "============================================================"
    SCRIPT
  }
}
