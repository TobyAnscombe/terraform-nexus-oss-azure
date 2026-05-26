###############################################################################
# Bootstrap — configure Nexus OSS via its REST API
#
#   1.  Wait for /service/rest/v1/status to return HTTP 200 (up to 2 min).
#       If unreachable after 2 min (VNet-private deployment), bootstrap is
#       skipped — config persists in the Azure Files share.
#   2.  Set the admin password (idempotent across re-runs).
#   3.  Enable global anonymous access.
#   4.  Create the package allowlist routing rule (pypi-allowlist).
#   5.  Create the hosted repo   (pypi-hosted).
#   6.  Create the proxy repo    (pypi-pypi.org  → https://pypi.org, routing rule applied).
#   7.  Create the group repo    (pypi-group = hosted + proxy, single pip URL).
#   8.  Create / update cleanup policy (pypi-proxy-cleanup, 90-day last-downloaded).
#   9.  Create / update two roles:
#         pypi-anonymous-reader      browse + read on pypi-group
#         pypi-authenticated-deployer browse + read on pypi-group + add on pypi-hosted
#   10. Lock the anonymous user to the reader role only.
#
# Supply-chain protection
#   The routing rule (ALLOW mode) means the proxy will only serve packages
#   whose /simple/{name} path matches the allowlist.  Everything else gets
#   a 404 from the proxy; the hosted repo is unaffected (admins control it).
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
    allowlist_version     = "4"
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

      # Create repo if it doesn't exist (checks by name, repo_type = hosted|proxy|group)
      nexus_create_repo() {
        local repo_type="$1" repo_name="$2" body="$3"
        EXISTS=$(curl -s -u "admin:$ADMIN_PASS" "$NEXUS/repositories" \
                   | jq -r --arg n "$repo_name" '.[] | select(.name==$n) | .name')
        if [ -n "$EXISTS" ]; then
          echo "    '$repo_name' already exists — skipping."
          return 0
        fi
        local http
        http=$(curl -s -o /tmp/nx_resp.txt -w "%%{http_code}" \
                 -u "admin:$ADMIN_PASS" \
                 -X POST "$NEXUS/repositories/pypi/$repo_type" \
                 -H "Content-Type: application/json" -d "$body")
        echo "    Created pypi/$repo_type '$repo_name' -> $http"
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
          "^/simple/pip(/.*)?$",           "^/packages/pip(/.*)?$",
          "^/simple/setuptools(/.*)?$",    "^/packages/setuptools(/.*)?$",
          "^/simple/wheel(/.*)?$",         "^/packages/wheel(/.*)?$",
          "^/simple/twine(/.*)?$",         "^/packages/twine(/.*)?$",
          "^/simple/build(/.*)?$",         "^/packages/build(/.*)?$",

          "^/simple/numpy(/.*)?$",         "^/packages/numpy(/.*)?$",
          "^/simple/pandas(/.*)?$",        "^/packages/pandas(/.*)?$",
          "^/simple/scipy(/.*)?$",         "^/packages/scipy(/.*)?$",
          "^/simple/polars(/.*)?$",        "^/packages/polars(/.*)?$",

          "^/simple/matplotlib(/.*)?$",    "^/packages/matplotlib(/.*)?$",
          "^/simple/seaborn(/.*)?$",       "^/packages/seaborn(/.*)?$",
          "^/simple/plotly(/.*)?$",        "^/packages/plotly(/.*)?$",
          "^/simple/bokeh(/.*)?$",         "^/packages/bokeh(/.*)?$",
          "^/simple/altair(/.*)?$",        "^/packages/altair(/.*)?$",
          "^/simple/kaleido(/.*)?$",       "^/packages/kaleido(/.*)?$",

          "^/simple/scikit-learn(/.*)?$",  "^/packages/scikit-learn(/.*)?$",
          "^/simple/statsmodels(/.*)?$",   "^/packages/statsmodels(/.*)?$",
          "^/simple/xgboost(/.*)?$",       "^/packages/xgboost(/.*)?$",
          "^/simple/lightgbm(/.*)?$",      "^/packages/lightgbm(/.*)?$",

          "^/simple/openpyxl(/.*)?$",      "^/packages/openpyxl(/.*)?$",
          "^/simple/xlrd(/.*)?$",          "^/packages/xlrd(/.*)?$",
          "^/simple/xlsxwriter(/.*)?$",    "^/packages/xlsxwriter(/.*)?$",
          "^/simple/pyarrow(/.*)?$",       "^/packages/pyarrow(/.*)?$",
          "^/simple/fastparquet(/.*)?$",   "^/packages/fastparquet(/.*)?$",
          "^/simple/sqlalchemy(/.*)?$",    "^/packages/sqlalchemy(/.*)?$",
          "^/simple/psycopg2-binary(/.*)?$","^/packages/psycopg2-binary(/.*)?$",
          "^/simple/pymysql(/.*)?$",       "^/packages/pymysql(/.*)?$",
          "^/simple/pyodbc(/.*)?$",        "^/packages/pyodbc(/.*)?$",

          "^/simple/tqdm(/.*)?$",          "^/packages/tqdm(/.*)?$",
          "^/simple/joblib(/.*)?$",        "^/packages/joblib(/.*)?$",
          "^/simple/numba(/.*)?$",         "^/packages/numba(/.*)?$",
          "^/simple/dask(/.*)?$",          "^/packages/dask(/.*)?$",
          "^/simple/requests(/.*)?$",      "^/packages/requests(/.*)?$",
          "^/simple/httpx(/.*)?$",         "^/packages/httpx(/.*)?$",
          "^/simple/aiohttp(/.*)?$",       "^/packages/aiohttp(/.*)?$",
          "^/simple/python-dateutil(/.*)?$","^/packages/python-dateutil(/.*)?$",
          "^/simple/pytz(/.*)?$",          "^/packages/pytz(/.*)?$",
          "^/simple/tzdata(/.*)?$",        "^/packages/tzdata(/.*)?$",
          "^/simple/six(/.*)?$",           "^/packages/six(/.*)?$",
          "^/simple/certifi(/.*)?$",       "^/packages/certifi(/.*)?$",
          "^/simple/charset-normalizer(/.*)?$","^/packages/charset-normalizer(/.*)?$",
          "^/simple/idna(/.*)?$",          "^/packages/idna(/.*)?$",
          "^/simple/urllib3(/.*)?$",       "^/packages/urllib3(/.*)?$",
          "^/simple/packaging(/.*)?$",     "^/packages/packaging(/.*)?$",
          "^/simple/click(/.*)?$",         "^/packages/click(/.*)?$",
          "^/simple/pydantic(/.*)?$",      "^/packages/pydantic(/.*)?$",
          "^/simple/pydantic-core(/.*)?$", "^/packages/pydantic-core(/.*)?$",
          "^/simple/typing-extensions(/.*)?$","^/packages/typing-extensions(/.*)?$",
          "^/simple/attrs(/.*)?$",         "^/packages/attrs(/.*)?$",
          "^/simple/annotated-types(/.*)?$","^/packages/annotated-types(/.*)?$",

          "^/simple/jupyter(/.*)?$",       "^/packages/jupyter(/.*)?$",
          "^/simple/jupyterlab(/.*)?$",    "^/packages/jupyterlab(/.*)?$",
          "^/simple/ipython(/.*)?$",       "^/packages/ipython(/.*)?$",
          "^/simple/ipykernel(/.*)?$",     "^/packages/ipykernel(/.*)?$",
          "^/simple/notebook(/.*)?$",      "^/packages/notebook(/.*)?$",
          "^/simple/nbformat(/.*)?$",      "^/packages/nbformat(/.*)?$",
          "^/simple/nbconvert(/.*)?$",     "^/packages/nbconvert(/.*)?$",
          "^/simple/ipywidgets(/.*)?$",    "^/packages/ipywidgets(/.*)?$",
          "^/simple/widgetsnbextension(/.*)?$","^/packages/widgetsnbextension(/.*)?$",

          "^/simple/pandera(/.*)?$",       "^/packages/pandera(/.*)?$"
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
      # 9. Restrict the anonymous user to the reader role only
      #    (Removes the default nx-anonymous role which allows unrestricted browse)
      # -----------------------------------------------------------------------
      echo "==> Assigning pypi-anonymous-reader to the anonymous user ..."
      nexus_put "security/users/anonymous" '{
        "userId":        "anonymous",
        "firstName":     "Anonymous",
        "lastName":      "User",
        "emailAddress":  "anonymous@example.org",
        "source":        "default",
        "status":        "active",
        "readOnly":      false,
        "roles":         ["pypi-anonymous-reader"],
        "externalRoles": []
      }'

      echo ""
      echo "============================================================"
      echo " Nexus OSS ready."
      echo " pip index : ${local.pypi_simple_url}"
      echo " pip upload: ${local.pypi_upload_url}"
      echo "============================================================"
    SCRIPT
  }
}
