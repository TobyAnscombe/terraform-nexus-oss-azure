locals {
  storage_account_name = "stnexus${var.environment}${random_string.suffix.result}"
  dns_name_label       = "${var.dns_name_label_prefix}-${random_string.suffix.result}"

  # The hostname used in every URL.
  # Public mode : Azure-assigned FQDN  (e.g. nexus-oss-3g1xti.uksouth.azurecontainer.io)
  # Private mode: private IP assigned to the container in the VNet subnet
  nexus_host = var.vnet_integrated ? azurerm_container_group.nexus.ip_address : azurerm_container_group.nexus.fqdn

  nexus_base_url = "http://${local.nexus_host}:8081"
  nexus_api_url  = "${local.nexus_base_url}/service/rest/v1"

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
