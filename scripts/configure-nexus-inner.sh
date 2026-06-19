#!/bin/bash
# Nexus Phase 2 configuration — runs INSIDE the ACI container against localhost:8081.
# Invoked by configure-nexus.sh / configure-nexus.ps1 via az container exec.
#
# The outer script prepends:  PW='<admin-password>'
# before this file's body, so PW is available as a shell variable.
set -euo pipefail

: "${PW:?PW is required — run via configure-nexus.sh/.ps1}"
BASE='http://localhost:8081'
AUTH="admin:${PW}"

echo "=== Phase 2 Nexus configuration ==="

# POST to create; on 409/422 (already exists) PUT to update.
post_or_put() {
  local cp="$1" up="$2" body="$3" code
  code=$(curl -s -u "$AUTH" -X POST "$BASE$cp" \
    -H 'Content-Type: application/json' -d "$body" \
    -o /tmp/nx -w '%{http_code}')
  if [ "$code" = "409" ] || [ "$code" = "422" ] || [ "$code" = "400" ]; then
    code=$(curl -s -u "$AUTH" -X PUT "$BASE$up" \
      -H 'Content-Type: application/json' -d "$body" \
      -o /tmp/nx -w '%{http_code}')
  fi
  if [[ "$code" != 2* ]]; then
    echo "  FAIL($code) $cp: $(head -c 300 /tmp/nx 2>/dev/null)"; return 1
  fi
  echo "  OK($code) $cp"
}

do_put() {
  local path="$1" body="$2" code
  code=$(curl -s -u "$AUTH" -X PUT "$BASE$path" \
    -H 'Content-Type: application/json' -d "$body" \
    -o /tmp/nx -w '%{http_code}')
  if [[ "$code" != 2* ]]; then
    echo "  FAIL($code) PUT $path: $(head -c 300 /tmp/nx 2>/dev/null)"; return 1
  fi
  echo "  OK($code) PUT $path"
}

# ── 1. Anonymous access ───────────────────────────────────────────────────────
echo "--- Anonymous access"
do_put '/service/rest/v1/security/anonymous' \
  '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}'

# ── 2. PyPI routing rule ──────────────────────────────────────────────────────
echo "--- PyPI routing rule"
PYPI_PKGS=(
  pip setuptools wheel twine build poetry pytest
  numpy pandas scipy polars pyarrow dask pyspark
  matplotlib seaborn plotly bokeh altair kaleido missingno
  scikit-learn xgboost lightgbm statsmodels lifelines pingouin mlflow
  shap lime eli5 pandera great-expectations
  openpyxl xlrd xlsxwriter fastparquet
  sqlalchemy psycopg2-binary pymysql pyodbc
  jupyter jupyterlab ipython ipykernel notebook
  nbformat nbconvert ipywidgets widgetsnbextension
  joblib numba tqdm requests httpx aiohttp
  python-dateutil pytz tzdata six
  certifi charset-normalizer idna urllib3
  packaging click
  pydantic pydantic-core typing-extensions attrs annotated-types
)

pypi_m='['
for pkg in "${PYPI_PKGS[@]}"; do
  e="${pkg//./\\.}"
  pypi_m+="\"^/simple/${pkg}(/.*)?$\","
  pypi_m+="\"^/packages(.*/)?${e}[-_]\","
done
pypi_m="${pypi_m%,}]"

post_or_put '/service/rest/v1/routing-rules' \
  '/service/rest/v1/routing-rules/pypi-allowlist' \
  "{\"name\":\"pypi-allowlist\",\"description\":\"Supply-chain gate: only approved packages pass through the PyPI proxy\",\"mode\":\"ALLOW\",\"matchers\":${pypi_m}}"

# ── 3. R / CRAN routing rule ──────────────────────────────────────────────────
echo "--- R CRAN routing rule"
R_PKGS=(
  rlang vctrs lifecycle cli glue magrittr generics
  R6 Rcpp withr pkgconfig ellipsis
  tibble purrr readr forcats hms vroom
  tidyselect pillar fansi utf8 crayon bit64 bit
  tidyverse dplyr tidyr stringr stringi
  data.table lubridate broom modelr
  haven readxl openxlsx rio foreign
  cellranger zip jsonlite curl httr
  ggplot2 scales gtable isoband farver labeling
  munsell RColorBrewer viridisLite colorspace MASS
  fuzzyjoin stringdist
)

# Four global PACKAGES index matchers; \\. in single-quoted string = literal \\. in JSON = \. regex (literal dot).
r_m='["^/src/contrib/PACKAGES(\\.[^/]*)?$","^/src/contrib/Meta/","^/bin/windows/contrib/[^/]+/PACKAGES(\\.[^/]*)?$","^/bin/macosx/[^/]+/contrib/[^/]+/PACKAGES(\\.[^/]*)?$"'
for pkg in "${R_PKGS[@]}"; do
  e="${pkg//./\\.}"
  r_m+=",\"^/src/contrib/${e}_\""
  r_m+=",\"^/bin/windows/contrib/[^/]+/${e}_\""
  r_m+=",\"^/bin/macosx/[^/]+/contrib/[^/]+/${e}_\""
done
r_m+=']'

post_or_put '/service/rest/v1/routing-rules' \
  '/service/rest/v1/routing-rules/r-cran-allowlist' \
  "{\"name\":\"r-cran-allowlist\",\"description\":\"Supply-chain gate: only approved R packages pass through the CRAN proxy\",\"mode\":\"ALLOW\",\"matchers\":${r_m}}"

# ── 4. PyPI repositories ──────────────────────────────────────────────────────
echo "--- PyPI repositories"

post_or_put '/service/rest/v1/repositories/pypi/hosted' \
  '/service/rest/v1/repositories/pypi/hosted/pypi-hosted' \
  '{"name":"pypi-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}'

post_or_put '/service/rest/v1/repositories/pypi/proxy' \
  '/service/rest/v1/repositories/pypi/proxy/pypi-pypi.org' \
  '{"name":"pypi-pypi.org","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"proxy":{"remoteUrl":"https://pypi.org","contentMaxAge":1440,"metadataMaxAge":1440},"negativeCache":{"enabled":true,"timeToLive":1440},"httpClient":{"blocked":false,"autoBlock":true},"routingRuleName":"pypi-allowlist"}'

post_or_put '/service/rest/v1/repositories/pypi/group' \
  '/service/rest/v1/repositories/pypi/group/pypi-group' \
  '{"name":"pypi-group","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"group":{"memberNames":["pypi-hosted","pypi-pypi.org"]}}'

# ── 5. R repositories ─────────────────────────────────────────────────────────
echo "--- R repositories"

post_or_put '/service/rest/v1/repositories/r/hosted' \
  '/service/rest/v1/repositories/r/hosted/r-hosted' \
  '{"name":"r-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}'

post_or_put '/service/rest/v1/repositories/r/proxy' \
  '/service/rest/v1/repositories/r/proxy/r-cran.r-project.org' \
  '{"name":"r-cran.r-project.org","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"proxy":{"remoteUrl":"https://cran.r-project.org","contentMaxAge":1440,"metadataMaxAge":1440},"negativeCache":{"enabled":true,"timeToLive":1440},"httpClient":{"blocked":false,"autoBlock":true},"routingRuleName":"r-cran-allowlist"}'

post_or_put '/service/rest/v1/repositories/r/group' \
  '/service/rest/v1/repositories/r/group/r-group' \
  '{"name":"r-group","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"group":{"memberNames":["r-hosted","r-cran.r-project.org"]}}'

# ── 6. Roles ──────────────────────────────────────────────────────────────────
echo "--- Roles"

post_or_put '/service/rest/v1/security/roles' \
  '/service/rest/v1/security/roles/pypi-anonymous-reader' \
  '{"id":"pypi-anonymous-reader","name":"PyPI Anonymous Reader","description":"Browse and download allowlisted packages via pypi-group (no upload)","privileges":["nx-repository-view-pypi-pypi-group-browse","nx-repository-view-pypi-pypi-group-read"],"roles":[]}'

post_or_put '/service/rest/v1/security/roles' \
  '/service/rest/v1/security/roles/pypi-authenticated-deployer' \
  '{"id":"pypi-authenticated-deployer","name":"PyPI Authenticated Deployer","description":"Browse/download via pypi-group; upload new packages to pypi-hosted","privileges":["nx-repository-view-pypi-pypi-group-browse","nx-repository-view-pypi-pypi-group-read","nx-repository-view-pypi-pypi-hosted-browse","nx-repository-view-pypi-pypi-hosted-read","nx-repository-view-pypi-pypi-hosted-add"],"roles":[]}'

post_or_put '/service/rest/v1/security/roles' \
  '/service/rest/v1/security/roles/r-anonymous-reader' \
  '{"id":"r-anonymous-reader","name":"R Anonymous Reader","description":"Browse and download allowlisted R packages via r-group (no upload)","privileges":["nx-repository-view-r-r-group-browse","nx-repository-view-r-r-group-read"],"roles":[]}'

post_or_put '/service/rest/v1/security/roles' \
  '/service/rest/v1/security/roles/r-authenticated-deployer' \
  '{"id":"r-authenticated-deployer","name":"R Authenticated Deployer","description":"Browse/download via r-group; upload new packages to r-hosted","privileges":["nx-repository-view-r-r-group-browse","nx-repository-view-r-r-group-read","nx-repository-view-r-r-hosted-browse","nx-repository-view-r-r-hosted-read","nx-repository-view-r-r-hosted-add"],"roles":[]}'

# ── 7. Anonymous user — scoped to reader roles only ───────────────────────────
echo "--- Anonymous user"
do_put '/service/rest/v1/security/users/anonymous' \
  '{"userId":"anonymous","firstName":"Anonymous","lastName":"User","emailAddress":"anonymous@example.org","password":"anonymous","status":"active","roles":["pypi-anonymous-reader","r-anonymous-reader"]}'

echo ""
echo "=== Phase 2 configuration complete ==="
