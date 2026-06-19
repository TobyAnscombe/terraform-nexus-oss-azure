output "nexus_url" {
  description = "Nexus OSS web UI and REST API root URL (via Cloudflare Tunnel)."
  value       = local.nexus_base_url
}

output "nexus_ui_url" {
  description = "Direct link to the Nexus web UI."
  value       = "${local.nexus_base_url}/#browse/browse"
}

# Gated URL consumed by Phase 2 (nexus/) via terraform_remote_state.
# The depends_on ensures this output is not written to state until Nexus has
# finished initialising — preventing the nexus provider from connecting too early.
output "nexus_base_url" {
  description = "Nexus base URL (Cloudflare Tunnel) — only available after the 2-minute startup wait."
  value       = local.nexus_base_url
  depends_on  = [time_sleep.nexus_ready]
}

output "container_group_ip" {
  description = "Private IP address of the container group within the VNet."
  value       = azurerm_container_group.nexus.ip_address
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "container_group_name" {
  value = azurerm_container_group.nexus.name
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "vnet_name" {
  description = "Name of the managed Virtual Network."
  value       = azurerm_virtual_network.main.name
}

output "aci_subnet_id" {
  description = "Resource ID of the subnet ACI is attached to."
  value       = azurerm_subnet.aci.id
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
# Ready-to-paste snippets — HTTPS via Cloudflare, no trusted-host needed
# ---------------------------------------------------------------------------

output "pip_conf_anonymous" {
  description = "pip.conf for users without credentials (read-only)."
  value       = <<-EOF
    [global]
    index-url = ${local.pypi_simple_url}
  EOF
}

output "pip_conf_authenticated" {
  description = "pip.conf for authenticated users (read + upload rights). Replace YOURUSER / YOURPASSWORD."
  value       = <<-EOF
    [global]
    index-url = https://YOURUSER:YOURPASSWORD@${trimprefix(local.pypi_simple_url, "https://")}
  EOF
}

output "twine_upload_example" {
  description = "twine command to publish a package. Any user with the pypi-authenticated-deployer role can run this."
  value       = "twine upload --repository-url ${local.pypi_upload_url} -u YOURUSER -p YOURPASSWORD dist/*"
}

# ---------------------------------------------------------------------------
# R / CRAN client configuration
# ---------------------------------------------------------------------------

output "r_cran_url" {
  description = "CRAN mirror URL — the root URL R appends platform-specific paths to."
  value       = local.r_cran_url
}

output "r_options_anonymous" {
  description = "R options() call for anonymous users (read-only). Paste into ~/.Rprofile."
  value       = <<-EOF
    options(repos = c(
      NEXUS = "${local.r_cran_url}",
      CRAN  = "@CRAN@"
    ))
  EOF
}

output "r_options_authenticated" {
  description = "R options() call for authenticated users (read + upload). Replace YOURUSER / YOURPASSWORD."
  value       = <<-EOF
    options(repos = c(
      NEXUS = "https://YOURUSER:YOURPASSWORD@${trimprefix(local.r_cran_url, "https://")}",
      CRAN  = "@CRAN@"
    ))
  EOF
}
