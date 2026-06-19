<#
.SYNOPSIS
  Bootstrap a fresh Nexus OSS instance: accept the EULA then set the admin password.
.DESCRIPTION
  Both steps are idempotent — safe to re-run at any time.

  Required env vars (or named parameters):
    NEXUS_URL      Base URL, e.g. https://nexus.example.com
    NEW_PASSWORD   Target admin password

  Optional env vars (Cloudflare Access service token):
    CF_ACCESS_CLIENT_ID
    CF_ACCESS_CLIENT_SECRET
#>
param(
  [string] $NexusUrl        = $env:NEXUS_URL,
  [string] $NewPassword     = $env:NEW_PASSWORD,
  [string] $CfClientId      = $env:CF_ACCESS_CLIENT_ID,
  [string] $CfClientSecret  = $env:CF_ACCESS_CLIENT_SECRET
)

if (-not $NexusUrl)    { throw 'NEXUS_URL is required' }
if (-not $NewPassword) { throw 'NEW_PASSWORD is required' }

$base = $NexusUrl.TrimEnd('/')

function Get-AuthHeaders([string] $CurrentPassword) {
  $headers = @{}
  $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$CurrentPassword"))
  $headers['Authorization'] = "Basic $cred"
  if ($CfClientId) {
    $headers['CF-Access-Client-Id']     = $CfClientId
    $headers['CF-Access-Client-Secret'] = $CfClientSecret
  }
  return $headers
}

function Invoke-EulaAccept([string] $CurrentPassword) {
  $headers = Get-AuthHeaders -CurrentPassword $CurrentPassword
  $headers['Content-Type'] = 'application/json'
  Invoke-RestMethod -Uri "$base/service/rest/v1/system/eula" -Method PUT `
    -Headers $headers -Body '{"accepted":true}' -ErrorAction Stop
}

function Invoke-PasswordChange([string] $CurrentPassword) {
  $headers = Get-AuthHeaders -CurrentPassword $CurrentPassword
  $headers['Content-Type'] = 'text/plain'
  Invoke-RestMethod -Uri "$base/service/rest/v1/security/users/admin/change-password" `
    -Method PUT -Headers $headers -Body $NewPassword -ErrorAction Stop
}

# Step 1 — accept EULA (Nexus CE blocks all repository access until accepted).
try {
  Invoke-EulaAccept -CurrentPassword 'admin123'
} catch {
  try {
    Invoke-EulaAccept -CurrentPassword $NewPassword
  } catch {
    throw "Failed to accept EULA. Verify NEXUS_URL is reachable."
  }
}
Write-Host 'EULA accepted.'

# Step 2 — change admin password.
try {
  Invoke-PasswordChange -CurrentPassword 'admin123'
  Write-Host 'Nexus admin password set.'
} catch {
  try {
    Invoke-PasswordChange -CurrentPassword $NewPassword
    Write-Host 'Nexus admin password confirmed (already set).'
  } catch {
    throw "Failed to set Nexus admin password. Verify NEXUS_URL is reachable and credentials are correct."
  }
}
