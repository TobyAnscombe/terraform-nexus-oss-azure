<#
.SYNOPSIS
  Bootstrap a fresh Nexus OSS instance: accept the EULA then set the admin password.
.DESCRIPTION
  Both steps are idempotent — safe to re-run at any time.

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

# PS 5.1 (.NET Framework) defaults to TLS 1.0/1.1; Cloudflare requires TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = $NexusUrl.TrimEnd('/')

function Get-AuthHeaders([string] $CurrentPassword) {
  $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$CurrentPassword"))
  return @{ Authorization = "Basic $cred" }
}

function Invoke-NexusRequest([string] $Uri, [string] $Method, [hashtable] $Headers, [string] $Body) {
  try {
    Invoke-WebRequest -Uri $Uri -Method $Method -Headers $Headers -Body $Body `
      -UseBasicParsing -ErrorAction Stop | Out-Null
  } catch {
    # Extract HTTP status code if available; fall back to raw exception message.
    $status = $null
    try { $status = $_.Exception.Response.StatusCode.value__ } catch {}
    if ($status) { throw "HTTP $status" } else { throw $_.Exception.Message }
  }
}

function Invoke-EulaAccept([string] $CurrentPassword) {
  $headers = Get-AuthHeaders -CurrentPassword $CurrentPassword
  $headers['Content-Type'] = 'application/json'
  Invoke-NexusRequest -Uri "$base/service/rest/v1/system/eula" -Method PUT `
    -Headers $headers -Body '{"accepted":true}'
}

function Invoke-PasswordChange([string] $CurrentPassword) {
  $headers = Get-AuthHeaders -CurrentPassword $CurrentPassword
  $headers['Content-Type'] = 'text/plain'
  Invoke-NexusRequest -Uri "$base/service/rest/v1/security/users/admin/change-password" `
    -Method PUT -Headers $headers -Body $NewPassword
}

# Step 1 — accept EULA (Nexus CE blocks all repository access until accepted).
$eulaErr1 = $null; $eulaErr2 = $null
try { Invoke-EulaAccept -CurrentPassword 'admin123'   } catch { $eulaErr1 = $_.Exception.Message }
if ($eulaErr1) {
  try { Invoke-EulaAccept -CurrentPassword $NewPassword } catch { $eulaErr2 = $_.Exception.Message }
}
if ($eulaErr1 -and $eulaErr2) {
  throw "Failed to accept EULA at $base - admin123: $eulaErr1 / new_password: $eulaErr2"
}
Write-Host 'EULA accepted.'

# Step 2 — change admin password.
$pwErr1 = $null; $pwErr2 = $null
try { Invoke-PasswordChange -CurrentPassword 'admin123'   } catch { $pwErr1 = $_.Exception.Message }
if ($pwErr1) {
  try { Invoke-PasswordChange -CurrentPassword $NewPassword } catch { $pwErr2 = $_.Exception.Message }
}
if ($pwErr1 -and $pwErr2) {
  throw "Failed to set admin password at $base - admin123: $pwErr1 / new_password: $pwErr2"
}
if ($pwErr1) { Write-Host 'Nexus admin password confirmed (already set).' } else { Write-Host 'Nexus admin password set.' }
