<#
.SYNOPSIS
    Phase 2 smoke test — validates Nexus configuration applied by nexus/main.tf.
.DESCRIPTION
    Checks anonymous access, allowlist routing, repo existence, routing rules,
    and admin password change. Requires curl.exe (built into Windows 11).
.PARAMETER NexusUrl
    Nexus base URL. Reads from terraform output in infra/ if not supplied.
.PARAMETER AdminPassword
    Nexus admin password. Prompts if not supplied.
.EXAMPLE
    .\scripts\smoke-test-phase2.ps1
    .\scripts\smoke-test-phase2.ps1 -NexusUrl http://nexus-oss-abc123.uksouth.azurecontainer.io -AdminPassword 'MyP@ss'
#>
param(
    [string]$NexusUrl,
    [string]$AdminPassword
)

Set-StrictMode -Version Latest

# -- Resolve URL --------------------------------------------------------------
if (-not $NexusUrl) {
    $infraDir = Join-Path (Join-Path $PSScriptRoot '..') 'infra'
    Push-Location $infraDir
    try   { $NexusUrl = (terraform output -raw nexus_url 2>$null).Trim() }
    finally { Pop-Location }
}
if (-not $NexusUrl) {
    Write-Error 'Nexus URL not found. Pass -NexusUrl or run infra/ apply first.'
    exit 1
}
$NexusUrl = $NexusUrl.TrimEnd('/')

if (-not $AdminPassword) {
    $AdminPassword = Read-Host 'Enter admin password'
}

# -- Helpers ------------------------------------------------------------------
$pass = 0
$fail = 0

function CheckHttp {
    param([string]$Label, [string]$Url, [int[]]$Expect = @(200), [string[]]$CurlArgs = @())
    $curlArgs2 = @('-s', '-o', 'NUL', '-w', '%{http_code}') + $CurlArgs + @($Url)
    $raw       = curl.exe @curlArgs2 2>$null
    $code      = if ($raw -match '^\d{3}$') { [int]$raw } else { 0 }
    $ok    = $code -in $Expect
    if ($ok) {
        Write-Host ("  [PASS] " + $Label) -ForegroundColor Green
        $script:pass++
    } else {
        $want = ($Expect | ForEach-Object { "$_" }) -join '/'
        Write-Host ("  [FAIL] " + $Label + "  (HTTP $code, expected $want)") -ForegroundColor Red
        Write-Host ("         $Url") -ForegroundColor DarkGray
        $script:fail++
    }
}

function CheckBody {
    param([string]$Label, [string]$Url, [string]$Contains, [string[]]$CurlArgs = @())
    $curlArgs2 = @('-sf') + $CurlArgs + @($Url)
    $body      = curl.exe @curlArgs2 2>$null
    $ok   = $LASTEXITCODE -eq 0 -and $body -like "*$Contains*"
    if ($ok) {
        Write-Host ("  [PASS] " + $Label) -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host ("  [FAIL] " + $Label + "  (expected to find '$Contains' in response)") -ForegroundColor Red
        $script:fail++
    }
}

$adminAuth  = @('-u', "admin:$AdminPassword")
$defaultAuth = @('-u', 'admin:admin123')
$sep = '-' * 60

# -- Anonymous checks ----------------------------------------------------------
Write-Host ""
Write-Host "Nexus Phase 2 smoke test  $NexusUrl"
Write-Host $sep

Write-Host ""
Write-Host "Anonymous access"
CheckHttp 'PyPI group index readable'           "$NexusUrl/repository/pypi-group/simple/"
CheckHttp 'Allowlisted package accessible (numpy)' "$NexusUrl/repository/pypi-group/simple/numpy/"
CheckHttp 'Blocked package denied (flask)'      "$NexusUrl/repository/pypi-group/simple/flask/"   -Expect @(403, 404)
CheckHttp 'CRAN PACKAGES index readable'        "$NexusUrl/repository/r-group/src/contrib/PACKAGES.gz"
CheckHttp 'Anonymous write rejected (pypi-hosted)' "$NexusUrl/repository/pypi-hosted/" -Expect @(401) -CurlArgs @('-X', 'POST')

# -- pip client tests ---------------------------------------------------------
Write-Host ""
Write-Host "pip client"

$trustedHost = ($NexusUrl -replace '^https?://', '')

function CheckPip {
    param([string]$Label, [string]$Package, [bool]$ExpectPass)
    if (-not (Get-Command pip -ErrorAction SilentlyContinue)) {
        Write-Host "  [SKIP] $Label  (pip not found)" -ForegroundColor DarkGray
        return
    }
    $out = pip index versions $Package `
        --index-url "$NexusUrl/repository/pypi-group/simple/" `
        --trusted-host $trustedHost `
        2>&1 | Out-String
    if ($ExpectPass) {
        if ($out -match 'Available versions|' + $Package) {
            Write-Host ("  [PASS] " + $Label) -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host ("  [FAIL] " + $Label + "  (expected pip to resolve package)") -ForegroundColor Red
            $script:fail++
        }
    } else {
        if ($out -match 'Could not find|No matching|not find a version') {
            Write-Host ("  [PASS] " + $Label + "  (correctly blocked)") -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host ("  [FAIL] " + $Label + "  (expected block, pip did not report error)") -ForegroundColor Red
            $script:fail++
        }
    }
}

CheckPip 'pip install pandas (allowlisted)'  'pandas' $true
CheckPip 'pip install flask  (blocked)'      'flask'  $false

# -- Admin password checks -----------------------------------------------------
Write-Host ""
Write-Host "Admin credentials"
CheckHttp 'Admin password accepted'             "$NexusUrl/service/rest/v1/security/users" -CurlArgs $adminAuth
CheckHttp 'Default password (admin123) rejected' "$NexusUrl/service/rest/v1/security/users" -Expect @(401) -CurlArgs $defaultAuth

# -- Repository existence ------------------------------------------------------
Write-Host ""
Write-Host "Repositories"
foreach ($repo in @('pypi-hosted', 'pypi-pypi.org', 'pypi-group', 'r-hosted', 'r-cran.r-project.org', 'r-group')) {
    CheckBody "Repo '$repo' exists" "$NexusUrl/service/rest/v1/repositories" -Contains $repo -CurlArgs $adminAuth
}

# -- Routing rules -------------------------------------------------------------
Write-Host ""
Write-Host "Routing rules"
CheckHttp 'pypi-allowlist exists'    "$NexusUrl/service/rest/v1/routing-rules/pypi-allowlist"   -CurlArgs $adminAuth
CheckHttp 'r-cran-allowlist exists'  "$NexusUrl/service/rest/v1/routing-rules/r-cran-allowlist" -CurlArgs $adminAuth

# -- Anonymous user roles ------------------------------------------------------
Write-Host ""
Write-Host "Anonymous user roles"
CheckBody 'anonymous user has pypi-anonymous-reader' "$NexusUrl/service/rest/v1/security/users?userId=anonymous" -Contains 'pypi-anonymous-reader' -CurlArgs $adminAuth
CheckBody 'anonymous user has r-anonymous-reader'    "$NexusUrl/service/rest/v1/security/users?userId=anonymous" -Contains 'r-anonymous-reader'    -CurlArgs $adminAuth

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host $sep
$colour = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "$pass passed, $fail failed" -ForegroundColor $colour
Write-Host ""

if ($fail -gt 0) { exit 1 }
