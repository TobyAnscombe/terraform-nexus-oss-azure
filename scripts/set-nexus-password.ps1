<#
.SYNOPSIS
  Bootstrap a fresh Nexus OSS instance: accept the EULA then set the admin password.
.DESCRIPTION
  Both steps are idempotent — safe to re-run at any time.

  Uses curl.exe (C:\Windows\System32\curl.exe, built into Windows 10 1803+)
  rather than Invoke-WebRequest. curl.exe handles TLS 1.2+, system proxy
  settings, and PUT requests reliably on PS 5.1 / .NET Framework.

  Required env vars (or named parameters):
    NEXUS_URL      Base URL, e.g. https://nexus.example.com
    NEW_PASSWORD   Target admin password
#>
param(
  [string] $NexusUrl    = $env:NEXUS_URL,
  [string] $NewPassword = $env:NEW_PASSWORD
)

if (-not $NexusUrl)    { throw 'NEXUS_URL is required' }
if (-not $NewPassword) { throw 'NEW_PASSWORD is required' }

$base = $NexusUrl.TrimEnd('/')

function Invoke-NexusCurl([string]$Auth, [string]$Uri, [string]$ContentType, [string]$Body) {
  # Append a sentinel so we can split body from status code in one pass.
  $raw = & curl.exe -s -u $Auth -X PUT -H "Content-Type: $ContentType" -d $Body `
    -w '<<<STATUS>>>%{http_code}' $Uri 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "curl connection error (exit $LASTEXITCODE)"
  }
  $joined = $raw -join ''
  $parts  = $joined -split '<<<STATUS>>>'
  $code   = [int]$parts[-1]
  if ($code -lt 200 -or $code -ge 300) {
    $snippet = if ($parts.Count -gt 1) { $parts[0].Substring(0, [Math]::Min(300, $parts[0].Length)) } else { '' }
    throw "HTTP $code$(if ($snippet) { ': ' + $snippet })"
  }
}

# Step 1 — accept EULA (Nexus CE blocks all repository access until accepted).
$eulaErr1 = $null; $eulaErr2 = $null
try   { Invoke-NexusCurl 'admin:admin123'    "$base/service/rest/v1/system/eula" 'application/json' '{"accepted":true}' }
catch { $eulaErr1 = $_.Exception.Message }
if ($eulaErr1) {
  try   { Invoke-NexusCurl "admin:$NewPassword" "$base/service/rest/v1/system/eula" 'application/json' '{"accepted":true}' }
  catch { $eulaErr2 = $_.Exception.Message }
}
if ($eulaErr1 -and $eulaErr2) {
  throw "Failed to accept EULA at $base - admin123: $eulaErr1 / new_password: $eulaErr2"
}
Write-Host 'EULA accepted.'

# Step 2 — change admin password.
$pwErr1 = $null; $pwErr2 = $null
try   { Invoke-NexusCurl 'admin:admin123'    "$base/service/rest/v1/security/users/admin/change-password" 'text/plain' $NewPassword }
catch { $pwErr1 = $_.Exception.Message }
if ($pwErr1) {
  try   { Invoke-NexusCurl "admin:$NewPassword" "$base/service/rest/v1/security/users/admin/change-password" 'text/plain' $NewPassword }
  catch { $pwErr2 = $_.Exception.Message }
}
if ($pwErr1 -and $pwErr2) {
  throw "Failed to set admin password at $base - admin123: $pwErr1 / new_password: $pwErr2"
}
if ($pwErr1) { Write-Host 'Nexus admin password confirmed (already set).' } else { Write-Host 'Nexus admin password set.' }
