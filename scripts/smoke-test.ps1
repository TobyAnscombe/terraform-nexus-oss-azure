<#
.SYNOPSIS
    End-to-end smoke test for the Nexus OSS deployment.
.DESCRIPTION
    Validates the nginx -> Nexus proxy chain, anonymous access, PyPI allowlist
    routing, and the CRAN proxy. Requires curl.exe (built into Windows 11).

    Phase 1 checks: need infra/ applied.
    Phase 2 checks: need nexus/ applied (repos, routing rules, anonymous access).
.PARAMETER NexusUrl
    Nexus base URL. Reads from terraform output in infra/ if not supplied.
.EXAMPLE
    .\scripts\smoke-test.ps1
    .\scripts\smoke-test.ps1 -NexusUrl http://nexus-oss-abc123.uksouth.azurecontainer.io
#>
param([string]$NexusUrl)

Set-StrictMode -Version Latest

# -- Resolve URL --------------------------------------------------------------
if (-not $NexusUrl) {
    $root     = Join-Path $PSScriptRoot '..'
    $infraDir = Join-Path $root 'infra'
    $tfExe    = if (Get-Command terraform -ErrorAction SilentlyContinue) { 'terraform' }
                elseif (Test-Path (Join-Path $root 'terraform.exe'))     { Join-Path $root 'terraform.exe' }
                else                                                      { $null }
    if ($tfExe) {
        Push-Location $infraDir
        try   { $NexusUrl = (& $tfExe output -raw nexus_url 2>$null).Trim() }
        catch { $NexusUrl = '' }
        finally { Pop-Location }
    }
}
if (-not $NexusUrl) {
    $tfvars = Join-Path (Join-Path $PSScriptRoot '..') 'infra\terraform.tfvars'
    if (Test-Path $tfvars) {
        $line = (Get-Content $tfvars | Select-String 'cloudflare_tunnel_hostname').Line
        if ($line -match '=\s*"([^"]+)"') { $NexusUrl = "https://$($Matches[1])" }
    }
}
if (-not $NexusUrl) {
    Write-Error 'Nexus URL not found. Pass -NexusUrl or ensure cloudflare_tunnel_hostname is set in infra/terraform.tfvars.'
    exit 1
}
$NexusUrl = $NexusUrl.TrimEnd('/')

# -- Helpers ------------------------------------------------------------------
$pass = 0
$fail = 0

function Check {
    param([string]$Label, [string]$Url, [int[]]$Expect = @(200))
    $raw  = curl.exe -s -o NUL -w '%{http_code}' $Url 2>$null
    $code = if ($raw -match '^\d{3}$') { [int]$raw } else { 0 }
    $ok   = $code -in $Expect
    if ($ok) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
        $script:pass++
    } else {
        $want = ($Expect | ForEach-Object { "$_" }) -join '/'
        Write-Host "  [FAIL] $Label  (HTTP $code, expected $want)" -ForegroundColor Red
        Write-Host "         $Url" -ForegroundColor DarkGray
        $script:fail++
    }
}

# -- Checks -------------------------------------------------------------------
Write-Host ""
Write-Host "Nexus smoke test  $NexusUrl"
Write-Host ("-" * 60)

Write-Host ""
Write-Host "Phase 1 - infrastructure"
Check 'Nexus up (Cloudflare Tunnel -> Nexus)' "$NexusUrl/service/rest/v1/status"

Write-Host ""
Write-Host "Phase 2 - Nexus configuration"
Check 'PyPI group index (anonymous read)'     "$NexusUrl/repository/pypi-group/simple/"
Check 'Allowlisted package accessible (numpy)' "$NexusUrl/repository/pypi-group/simple/numpy/"
Check 'Blocked package denied (flask)'        "$NexusUrl/repository/pypi-group/simple/flask/"  -Expect @(403, 404)
Check 'CRAN PACKAGES index (anonymous read)'  "$NexusUrl/repository/r-group/src/contrib/PACKAGES.gz"

# -- Summary ------------------------------------------------------------------
Write-Host ""
Write-Host ("-" * 60)
$colour = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "$pass passed, $fail failed" -ForegroundColor $colour
Write-Host ""

if ($fail -gt 0) { exit 1 }
