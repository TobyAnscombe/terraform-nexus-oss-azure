locals {
  storage_account_name = "stnexus${var.environment}${random_string.suffix.result}"
  dns_name_label       = "${var.dns_name_label_prefix}-${random_string.suffix.result}"

  # True when ACI should receive a private IP (no public DNS label).
  # Triggered by either vnet_integrated = true OR an existing_subnet_id being supplied.
  use_vnet = var.vnet_integrated || var.existing_subnet_id != null

  # Subnet ID ACI joins when use_vnet = true.
  # Prefers the caller-supplied existing subnet; falls back to the managed subnet.
  aci_subnet_id = (
    var.existing_subnet_id != null
    ? var.existing_subnet_id
    : try(azurerm_subnet.aci[0].id, null)
  )

  # The hostname used in every URL.
  # Public mode : Azure-assigned FQDN  (e.g. nexus-oss-3g1xti.uksouth.azurecontainer.io)
  # Private mode: private IP assigned to the container in the VNet subnet
  nexus_host = local.use_vnet ? azurerm_container_group.nexus.ip_address : azurerm_container_group.nexus.fqdn

  nexus_base_url = "http://${local.nexus_host}:8081"

  # pip reads from the group (hosted first, then allowlist-filtered proxy)
  pypi_simple_url = "${local.nexus_base_url}/repository/pypi-group/simple/"
  # twine uploads go directly to the hosted repo
  pypi_upload_url = "${local.nexus_base_url}/repository/pypi-hosted/"

  # JVM tuning: heap ≈ 2/3 RAM, direct memory ≈ 1/3
  nexus_heap_gb   = max(1, floor(var.nexus_memory_gb * 0.67))
  nexus_direct_gb = max(1, floor(var.nexus_memory_gb * 0.33))
  nexus_jvm_opts = join(" ", [
    "-Xms${local.nexus_heap_gb}g",
    "-Xmx${local.nexus_heap_gb}g",
    "-XX:MaxDirectMemorySize=${local.nexus_direct_gb}g",
    "-Djava.util.prefs.userRoot=/nexus-data/javaprefs",
  ])

  common_tags = merge(
    {
      environment = var.environment
      managed_by  = "terraform"
      application = "nexus-oss"
    },
    var.tags
  )
}
