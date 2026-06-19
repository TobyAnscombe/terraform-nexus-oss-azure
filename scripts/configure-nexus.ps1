<#
.SYNOPSIS
  Configure Nexus Phase 2 via az container exec — bypasses Cloudflare entirely.
.DESCRIPTION
  Uploads configure-nexus-inner.sh to the Nexus Azure Files share, then runs it
  inside the container against localhost:8081.  The admin password is passed as
  a base64-encoded env var so it never appears in the exec-command as plain text.

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

$pwB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NewPassword))

try {
  Write-Host 'Uploading configuration script...'
  az storage file upload `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --share-name nexus-data `
    --source $innerScript `
    --path configure-nexus-inner.sh `
    --output none
  if ($LASTEXITCODE -ne 0) { throw 'Failed to upload configuration script' }

  Write-Host 'Running configuration inside container...'
  az container exec `
    --resource-group $ResourceGroup `
    --name $ContainerGroup `
    --container-name nexus `
    --exec-command "env NX_PW_B64=$pwB64 bash /nexus-data/configure-nexus-inner.sh"
  if ($LASTEXITCODE -ne 0) { throw 'Configuration script execution failed' }
}
finally {
  Write-Host 'Cleaning up...'
  az storage file delete `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --share-name nexus-data `
    --path configure-nexus-inner.sh `
    --output none 2>$null
}
