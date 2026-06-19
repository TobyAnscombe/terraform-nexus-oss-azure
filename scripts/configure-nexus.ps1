<#
.SYNOPSIS
  Configure Nexus Phase 2 via az container exec — bypasses Cloudflare entirely.
.DESCRIPTION
  Reads configure-nexus-inner.sh, prepends the admin password as a PW variable,
  uploads the combined script to the Nexus Azure Files share, runs it inside the
  container against localhost:8081, then deletes it.

  Required env vars (or named parameters):
    NEW_PASSWORD    Nexus admin password (already set by bootstrap)
    RESOURCE_GROUP  Azure resource group name
    CONTAINER_GROUP ACI container group name  (e.g. aci-prod-nexus-oss)
    STORAGE_ACCOUNT Azure Storage account name
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

$innerScript = Join-Path $PSScriptRoot 'configure-nexus-inner.sh'
if (-not (Test-Path $innerScript)) {
  throw "configure-nexus-inner.sh not found at $innerScript"
}

Write-Host 'Fetching storage account key...'
$storageKey = (az storage account keys list `
  --account-name $StorageAccount `
  --resource-group $ResourceGroup `
  --query '[0].value' -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Failed to get storage account key' }

# Escape single quotes in the password for embedding in a bash single-quoted string:
# replace ' with '\'' (end-quote, escaped-quote, re-open).
$escapedPw = $NewPassword -replace "'", "'\\'''"

# Read inner script, skip its shebang, prepend the password line, ensure LF line endings.
$innerLines  = [System.IO.File]::ReadAllText($innerScript) -replace "`r`n", "`n"
$innerBody   = $innerLines -replace '^#!/[^\n]*\n', ''
$combined    = "#!/bin/bash`nPW='$escapedPw'`n" + $innerBody
$combinedLF  = $combined -replace "`r`n", "`n"

$tmpfile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "nexus-configure-$(Get-Random).sh")

try {
  [System.IO.File]::WriteAllText($tmpfile, $combinedLF, [System.Text.UTF8Encoding]::new($false))

  Write-Host 'Uploading configuration script...'
  az storage file upload `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --share-name nexus-data `
    --source $tmpfile `
    --path configure-nexus-tmp.sh `
    --output none
  if ($LASTEXITCODE -ne 0) { throw 'Failed to upload configuration script' }

  Write-Host 'Running configuration inside container...'
  az container exec `
    --resource-group $ResourceGroup `
    --name $ContainerGroup `
    --container-name nexus `
    --exec-command "bash /nexus-data/configure-nexus-tmp.sh"
  if ($LASTEXITCODE -ne 0) { throw 'Configuration script execution failed' }
}
finally {
  Write-Host 'Cleaning up...'
  az storage file delete `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --share-name nexus-data `
    --path configure-nexus-tmp.sh `
    --output none 2>$null
  Remove-Item -Path $tmpfile -Force -ErrorAction SilentlyContinue
}
