###############################################################################
# Azure Container Group — single Nexus OSS container
#
# ip_address_type and subnet_ids are conditional on var.vnet_integrated:
#
#   false (default) → Public IP + DNS label, no VNet attachment
#   true            → Private IP in snet-aci, no public DNS
#
# Changing vnet_integrated forces replacement of the container group.
###############################################################################

resource "azurerm_container_group" "nexus" {
  name                = "aci-${var.environment}-nexus-oss"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  os_type         = "Linux"
  ip_address_type = local.use_vnet ? "Private" : "Public"
  dns_name_label  = local.use_vnet ? null : local.dns_name_label
  subnet_ids      = local.use_vnet ? [local.aci_subnet_id] : null

  restart_policy = "Always"

  container {
    name   = "nexus"
    image  = "sonatype/nexus3:3.92.2"
    cpu    = var.nexus_cpu
    memory = var.nexus_memory_gb

    ports {
      port     = 8081
      protocol = "TCP"
    }

    environment_variables = {
      # Use a fixed initial password ('admin123') rather than a random one
      # written to /nexus-data/admin.password.  The bootstrap script
      # replaces it immediately with var.admin_password.
      NEXUS_SECURITY_RANDOMPASSWORD = "false"

      INSTALL4J_ADD_VM_PARAMS = local.nexus_jvm_opts
    }

    # /nexus-data: blob store, component DB, config, logs — persists across restarts
    volume {
      name                 = "nexus-data"
      mount_path           = "/nexus-data"
      read_only            = false
      storage_account_name = azurerm_storage_account.main.name
      storage_account_key  = azurerm_storage_account.main.primary_access_key
      share_name           = azurerm_storage_share.nexus_data.name
    }

    liveness_probe {
      http_get {
        path   = "/service/rest/v1/status"
        port   = 8081
        scheme = "Http"
      }
      initial_delay_seconds = 90
      period_seconds        = 30
      failure_threshold     = 10
      success_threshold     = 1
      timeout_seconds       = 10
    }
  }

  tags = local.common_tags
}
