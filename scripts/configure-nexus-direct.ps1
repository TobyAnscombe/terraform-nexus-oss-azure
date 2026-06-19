<#
.SYNOPSIS
  Configure Nexus directly via its public URL — no Azure access needed.
.DESCRIPTION
  Handles EULA acceptance, admin password change, and full Phase 2
  configuration (routing rules, repos, roles, anonymous access) in one pass.
  Use when Cloudflare is not blocking REST API calls.

  Required env vars (or named parameters):
    NEW_PASSWORD  Target admin password
    NEXUS_URL     Public base URL, e.g. https://nexus.htbplc.co.uk

  Optional:
    CURRENT_PASSWORD  Current admin password (default: admin123)
#>
param(
  [string] $NewPassword     = $env:NEW_PASSWORD,
  [string] $NexusUrl        = $env:NEXUS_URL,
  [string] $CurrentPassword = $env:CURRENT_PASSWORD
)

if (-not $CurrentPassword) { $CurrentPassword = 'admin123' }
if (-not $NewPassword) { throw 'NEW_PASSWORD is required' }
if (-not $NexusUrl)    { throw 'NEXUS_URL is required (e.g. https://nexus.example.com)' }

# Force TLS 1.2 for Windows PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base = $NexusUrl.TrimEnd('/')

function Get-NxStatusCode {
  param(
    [string] $Method,
    [string] $Path,
    [string] $Password,
    [string] $Body        = '',
    [string] $ContentType = 'application/json'
  )
  $auth   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:$Password"))
  $params = @{
    Method      = $Method
    Uri         = "$Base$Path"
    Headers     = @{ Authorization = "Basic $auth" }
    ErrorAction = 'Stop'
  }
  if ($Body) {
    $params.Body        = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $params.ContentType = $ContentType
  }
  try {
    return [int](Invoke-WebRequest @params).StatusCode
  } catch {
    $r = $_.Exception.Response
    if ($null -ne $r) { return [int]$r.StatusCode }
    throw
  }
}

# Try with CurrentPassword first, fall back to NewPassword (handles re-runs).
function Invoke-NxTryPw {
  param([string]$Method, [string]$Path, [string]$Body = '', [string]$ContentType = 'application/json')
  $code = Get-NxStatusCode $Method $Path $CurrentPassword $Body $ContentType
  if ($code -lt 200 -or $code -ge 300) {
    $code = Get-NxStatusCode $Method $Path $NewPassword $Body $ContentType
  }
  if ($code -ge 200 -and $code -lt 300) { Write-Host "  OK($code) $Method $Path" }
  else { throw "FAIL($code) $Method $Path" }
}

# POST to create; on 409/422/400 PUT to update.
function Invoke-NxPostOrPut {
  param([string]$CreatePath, [string]$UpdatePath, [string]$Body)
  $code = Get-NxStatusCode POST $CreatePath $NewPassword $Body
  if ($code -in @(400, 409, 422)) {
    $code = Get-NxStatusCode PUT $UpdatePath $NewPassword $Body
  }
  if ($code -ge 200 -and $code -lt 300) { Write-Host "  OK($code) $CreatePath" }
  else { throw "FAIL($code) $CreatePath" }
}

function Invoke-NxPut {
  param([string]$Path, [string]$Body)
  $code = Get-NxStatusCode PUT $Path $NewPassword $Body
  if ($code -ge 200 -and $code -lt 300) { Write-Host "  OK($code) PUT $Path" }
  else { throw "FAIL($code) PUT $Path" }
}

Write-Host '=== Nexus bootstrap + configuration ==='
Write-Host "Target: $Base"

# ── 1. EULA ───────────────────────────────────────────────────────────────────
Write-Host '--- EULA'
Invoke-NxTryPw PUT /service/rest/v1/system/eula '{"accepted":true}'

# ── 2. Admin password ─────────────────────────────────────────────────────────
Write-Host '--- Admin password'
Invoke-NxTryPw PUT /service/rest/v1/security/users/admin/change-password $NewPassword 'text/plain'

# ── 3. Anonymous access ───────────────────────────────────────────────────────
Write-Host '--- Anonymous access'
Invoke-NxPut /service/rest/v1/security/anonymous `
  '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}'

# ── 4. PyPI routing rule ──────────────────────────────────────────────────────
Write-Host '--- PyPI routing rule'
$pypiPkgs = @(
  'pip','setuptools','wheel','twine','build','poetry','pytest',
  'numpy','pandas','scipy','polars','pyarrow','dask','pyspark',
  'matplotlib','seaborn','plotly','bokeh','altair','kaleido','missingno',
  'scikit-learn','xgboost','lightgbm','statsmodels','lifelines','pingouin','mlflow',
  'shap','lime','eli5','pandera','great-expectations',
  'openpyxl','xlrd','xlsxwriter','fastparquet',
  'sqlalchemy','psycopg2-binary','pymysql','pyodbc',
  'jupyter','jupyterlab','ipython','ipykernel','notebook',
  'nbformat','nbconvert','ipywidgets','widgetsnbextension',
  'joblib','numba','tqdm','requests','httpx','aiohttp',
  'python-dateutil','pytz','tzdata','six',
  'certifi','charset-normalizer','idna','urllib3',
  'packaging','click',
  'pydantic','pydantic-core','typing-extensions','attrs','annotated-types'
)
$pypiMatchers = @()
foreach ($pkg in $pypiPkgs) {
  $e = $pkg -replace '\.', '\.'
  $pypiMatchers += "^/simple/$pkg(/.*)?`$"
  $pypiMatchers += "^/packages(.*/)?$e[-_]"
}
$pypiBody = [ordered]@{
  name        = 'pypi-allowlist'
  description = 'Supply-chain gate: only approved packages pass through the PyPI proxy'
  mode        = 'ALLOW'
  matchers    = $pypiMatchers
} | ConvertTo-Json -Compress -Depth 3
Invoke-NxPostOrPut /service/rest/v1/routing-rules /service/rest/v1/routing-rules/pypi-allowlist $pypiBody

# ── 5. R / CRAN routing rule ──────────────────────────────────────────────────
Write-Host '--- R CRAN routing rule'
$rPkgs = @(
  'rlang','vctrs','lifecycle','cli','glue','magrittr','generics',
  'R6','Rcpp','withr','pkgconfig','ellipsis',
  'tibble','purrr','readr','forcats','hms','vroom',
  'tidyselect','pillar','fansi','utf8','crayon','bit64','bit',
  'tidyverse','dplyr','tidyr','stringr','stringi',
  'data.table','lubridate','broom','modelr',
  'haven','readxl','openxlsx','rio','foreign',
  'cellranger','zip','jsonlite','curl','httr',
  'ggplot2','scales','gtable','isoband','farver','labeling',
  'munsell','RColorBrewer','viridisLite','colorspace','MASS',
  'fuzzyjoin','stringdist'
)
$rMatchers = @(
  '^/src/contrib/PACKAGES(\.[^/]*)?$',
  '^/src/contrib/Meta/',
  '^/bin/windows/contrib/[^/]+/PACKAGES(\.[^/]*)?$',
  '^/bin/macosx/[^/]+/contrib/[^/]+/PACKAGES(\.[^/]*)?$'
)
foreach ($pkg in $rPkgs) {
  $e = $pkg -replace '\.', '\.'
  $rMatchers += "^/src/contrib/${e}_"
  $rMatchers += "^/bin/windows/contrib/[^/]+/${e}_"
  $rMatchers += "^/bin/macosx/[^/]+/contrib/[^/]+/${e}_"
}
$rBody = [ordered]@{
  name        = 'r-cran-allowlist'
  description = 'Supply-chain gate: only approved R packages pass through the CRAN proxy'
  mode        = 'ALLOW'
  matchers    = $rMatchers
} | ConvertTo-Json -Compress -Depth 3
Invoke-NxPostOrPut /service/rest/v1/routing-rules /service/rest/v1/routing-rules/r-cran-allowlist $rBody

# ── 6. PyPI repositories ──────────────────────────────────────────────────────
Write-Host '--- PyPI repositories'
Invoke-NxPostOrPut /service/rest/v1/repositories/pypi/hosted `
  /service/rest/v1/repositories/pypi/hosted/pypi-hosted `
  '{"name":"pypi-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}'

Invoke-NxPostOrPut /service/rest/v1/repositories/pypi/proxy `
  /service/rest/v1/repositories/pypi/proxy/pypi-pypi.org `
  '{"name":"pypi-pypi.org","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"proxy":{"remoteUrl":"https://pypi.org","contentMaxAge":1440,"metadataMaxAge":1440},"negativeCache":{"enabled":true,"timeToLive":1440},"httpClient":{"blocked":false,"autoBlock":true},"routingRuleName":"pypi-allowlist"}'

Invoke-NxPostOrPut /service/rest/v1/repositories/pypi/group `
  /service/rest/v1/repositories/pypi/group/pypi-group `
  '{"name":"pypi-group","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"group":{"memberNames":["pypi-hosted","pypi-pypi.org"]}}'

# ── 7. R repositories ─────────────────────────────────────────────────────────
Write-Host '--- R repositories'
Invoke-NxPostOrPut /service/rest/v1/repositories/r/hosted `
  /service/rest/v1/repositories/r/hosted/r-hosted `
  '{"name":"r-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}'

Invoke-NxPostOrPut /service/rest/v1/repositories/r/proxy `
  /service/rest/v1/repositories/r/proxy/r-cran.r-project.org `
  '{"name":"r-cran.r-project.org","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"proxy":{"remoteUrl":"https://cran.r-project.org","contentMaxAge":1440,"metadataMaxAge":1440},"negativeCache":{"enabled":true,"timeToLive":1440},"httpClient":{"blocked":false,"autoBlock":true},"routingRuleName":"r-cran-allowlist"}'

Invoke-NxPostOrPut /service/rest/v1/repositories/r/group `
  /service/rest/v1/repositories/r/group/r-group `
  '{"name":"r-group","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"group":{"memberNames":["r-hosted","r-cran.r-project.org"]}}'

# ── 8. Roles ──────────────────────────────────────────────────────────────────
Write-Host '--- Roles'
Invoke-NxPostOrPut /service/rest/v1/security/roles `
  /service/rest/v1/security/roles/pypi-anonymous-reader `
  '{"id":"pypi-anonymous-reader","name":"PyPI Anonymous Reader","description":"Browse and download allowlisted packages via pypi-group (no upload)","privileges":["nx-repository-view-pypi-pypi-group-browse","nx-repository-view-pypi-pypi-group-read"],"roles":[]}'

Invoke-NxPostOrPut /service/rest/v1/security/roles `
  /service/rest/v1/security/roles/pypi-authenticated-deployer `
  '{"id":"pypi-authenticated-deployer","name":"PyPI Authenticated Deployer","description":"Browse/download via pypi-group; upload new packages to pypi-hosted","privileges":["nx-repository-view-pypi-pypi-group-browse","nx-repository-view-pypi-pypi-group-read","nx-repository-view-pypi-pypi-hosted-browse","nx-repository-view-pypi-pypi-hosted-read","nx-repository-view-pypi-pypi-hosted-add"],"roles":[]}'

Invoke-NxPostOrPut /service/rest/v1/security/roles `
  /service/rest/v1/security/roles/r-anonymous-reader `
  '{"id":"r-anonymous-reader","name":"R Anonymous Reader","description":"Browse and download allowlisted R packages via r-group (no upload)","privileges":["nx-repository-view-r-r-group-browse","nx-repository-view-r-r-group-read"],"roles":[]}'

Invoke-NxPostOrPut /service/rest/v1/security/roles `
  /service/rest/v1/security/roles/r-authenticated-deployer `
  '{"id":"r-authenticated-deployer","name":"R Authenticated Deployer","description":"Browse/download via r-group; upload new packages to r-hosted","privileges":["nx-repository-view-r-r-group-browse","nx-repository-view-r-r-group-read","nx-repository-view-r-r-hosted-browse","nx-repository-view-r-r-hosted-read","nx-repository-view-r-r-hosted-add"],"roles":[]}'

# ── 9. Anonymous user ─────────────────────────────────────────────────────────
Write-Host '--- Anonymous user'
Invoke-NxPut /service/rest/v1/security/users/anonymous `
  '{"userId":"anonymous","firstName":"Anonymous","lastName":"User","emailAddress":"anonymous@example.org","password":"anonymous","status":"active","roles":["pypi-anonymous-reader","r-anonymous-reader"]}'

Write-Host ''
Write-Host '=== Configuration complete ==='
