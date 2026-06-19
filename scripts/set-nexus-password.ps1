<#
.SYNOPSIS
  Bootstrap Nexus OSS via az container exec — bypasses Cloudflare entirely.
.DESCRIPTION
  Writes a temporary bash script to the Nexus Azure Files share (/nexus-data),
  runs it inside the container against localhost:8081, then deletes it.
  Using Azure ARM APIs means corporate network proxies and Cloudflare Bot Fight
  Mode do not interfere.

  Required env vars (or named parameters):
    NEW_PASSWORD    Target admin password
    RESOURCE_GROUP  Azure resource group name
    CONTAINER_GROUP Azure Container Instance group name
    STORAGE_ACCOUNT Azure Storage account name (for the nexus-data file share)
#>
param(
  [string] $NewPassword    = $env:NEW_PASSWORD,
  [string] $ResourceGroup  = $env:RESOURCE_GROUP,
  [string] $ContainerGroup = $env:CONTAINER_GROUP,
  [string] $StorageAccount = $env:STORAGE_ACCOUNT
)

if (-not $NewPassword)    { throw 'NEW_PASSWORD is required' }
if (-not $ResourceGroup)  { throw 'RESOURCE_GROUP is required' }
if (-not $ContainerGroup) { throw 'CONTAINER_GROUP is required' }
if (-not $StorageAccount) { throw 'STORAGE_ACCOUNT is required' }

# Fetch storage account key (requires Contributor or Storage Account Key Operator role).
Write-Host 'Fetching storage account key...'
$storageKey = (az storage account keys list `
  --account-name $StorageAccount `
  --resource-group $ResourceGroup `
  --query '[0].value' -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Failed to get storage account key' }

# Escape single quotes in the password for embedding in a bash single-quoted string:
# replace ' with '\'' (end-quote, escaped-quote, re-open).
$escapedPw = $NewPassword -replace "'", "'\\'''"

# Build the bash bootstrap script with LF line endings (required for Linux container).
# In PowerShell double-quoted here-strings, backtick escapes $; $escapedPw is expanded.
$script = @"
#!/bin/bash
# Runs inside the Nexus container against localhost:8081 - no Cloudflare involved.
PW='$escapedPw'
url='http://localhost:8081'

# Step 1: accept EULA (required since Nexus CE; idempotent).
curl -sf -u admin:admin123 -X PUT "`$url/service/rest/v1/system/eula" -H 'Content-Type: application/json' -d '{"accepted":true}' || curl -sf -u "admin:`$PW" -X PUT "`$url/service/rest/v1/system/eula" -H 'Content-Type: application/json' -d '{"accepted":true}'
echo 'EULA accepted.'

# Step 2: change admin password (idempotent - falls back if already changed).
curl -sf -u admin:admin123 -X PUT "`$url/service/rest/v1/security/users/admin/change-password" -H 'Content-Type: text/plain' -d "`$PW" || curl -sf -u "admin:`$PW" -X PUT "`$url/service/rest/v1/security/users/admin/change-password" -H 'Content-Type: text/plain' -d "`$PW"
echo 'Nexus admin password set.'
"@

$tmpfile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "nexus-bootstrap-$(Get-Random).sh")

try {
  # Write with LF line endings and UTF-8 without BOM (required for bash on Linux).
  $scriptLF = $script -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText($tmpfile, $scriptLF, [System.Text.UTF8Encoding]::new($false))

  # Upload bootstrap script to Azure Files.
  Write-Host 'Uploading bootstrap script to Azure Files...'
  az storage file upload `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --share-name nexus-data `
    --source $tmpfile `
    --path bootstrap-tmp.sh `
    --output none
  if ($LASTEXITCODE -ne 0) { throw 'Failed to upload bootstrap script' }

  # Execute inside container via Azure ARM APIs — no Cloudflare in the path.
  Write-Host 'Running bootstrap inside container...'
  az container exec `
    --resource-group $ResourceGroup `
    --name $ContainerGroup `
    --container-name nexus `
    --exec-command "bash /nexus-data/bootstrap-tmp.sh"
  if ($LASTEXITCODE -ne 0) { throw 'Bootstrap script execution failed' }

  # Clean up the temp script from Azure Files.
  Write-Host 'Cleaning up bootstrap script...'
  az storage file delete `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --share-name nexus-data `
    --path bootstrap-tmp.sh `
    --output none
  if ($LASTEXITCODE -ne 0) { Write-Warning 'Failed to delete bootstrap-tmp.sh from Azure Files - remove it manually' }
}
finally {
  Remove-Item -Path $tmpfile -Force -ErrorAction SilentlyContinue
}
