output "nexus_url" {
  description = "Nexus OSS web UI and REST API root URL."
  value       = local.nexus_base_url
}

output "nexus_ui_url" {
  description = "Direct link to the Nexus web UI."
  value       = "${local.nexus_base_url}/#browse/browse"
}

output "nexus_host" {
  description = "Hostname or IP used to reach Nexus (FQDN in public mode, private IP in VNet mode)."
  value       = local.nexus_host
}

output "container_group_fqdn" {
  description = "Public FQDN of the Azure Container Group (null in VNet mode)."
  value       = local.use_vnet ? null : azurerm_container_group.nexus.fqdn
}

output "container_group_ip" {
  description = "IP address of the container group (public IP in public mode, private IP in VNet mode)."
  value       = azurerm_container_group.nexus.ip_address
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "vnet_name" {
  description = "Name of the managed Virtual Network (null when existing_subnet_id is set)."
  value       = var.existing_subnet_id == null ? azurerm_virtual_network.main[0].name : null
}

output "aci_subnet_id" {
  description = "Resource ID of the subnet ACI is (or will be) attached to."
  value       = local.aci_subnet_id
}

# ---------------------------------------------------------------------------
# The two URLs everything needs
# ---------------------------------------------------------------------------

output "pypi_simple_url" {
  description = "pip index URL — works without credentials (anonymous read) and with credentials (authenticated read + upload)."
  value       = local.pypi_simple_url
}

output "pypi_upload_url" {
  description = "twine / pip upload endpoint for authenticated users."
  value       = local.pypi_upload_url
}

# ---------------------------------------------------------------------------
# Ready-to-paste snippets
# ---------------------------------------------------------------------------

output "pip_conf_anonymous" {
  description = "pip.conf for users without credentials (read-only)."
  value       = <<-EOF
    [global]
    index-url  = ${local.pypi_simple_url}
    trusted-host = ${local.nexus_host}
  EOF
}

output "pip_conf_authenticated" {
  description = "pip.conf for authenticated users (read + upload rights). Replace YOURUSER / YOURPASSWORD."
  value       = <<-EOF
    [global]
    index-url  = http://YOURUSER:YOURPASSWORD@${trimprefix(local.pypi_simple_url, "http://")}
    trusted-host = ${local.nexus_host}
  EOF
}

output "twine_upload_example" {
  description = "twine command to publish a package. Any user with the pypi-authenticated-deployer role can run this."
  value       = "twine upload --repository-url ${local.pypi_upload_url} -u YOURUSER -p YOURPASSWORD dist/*"
}
