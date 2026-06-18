locals {
  storage_account_name = "stnexus${var.environment}${random_string.suffix.result}"

  nexus_base_url = "https://${var.cloudflare_tunnel_hostname}"

  # pip reads from the group (hosted first, then allowlist-filtered proxy)
  pypi_simple_url = "${local.nexus_base_url}/repository/pypi-group/simple/"
  # twine uploads go directly to the hosted repo
  pypi_upload_url = "${local.nexus_base_url}/repository/pypi-hosted/"

  # R uses the group root URL; R itself appends /src/contrib/, /bin/windows/, etc.
  r_cran_url = "${local.nexus_base_url}/repository/r-group/"

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
