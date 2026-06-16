###############################################################################
# Storage Account + single File Share for all Nexus data
###############################################################################
resource "azurerm_storage_account" "main" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = var.storage_replication_type

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  share_properties {
    # Soft delete — 7-day recovery window for accidental file share deletion
    retention_policy {
      days = 7
    }

    smb {
      versions             = ["SMB3.0", "SMB3.1.1"]
      authentication_types = ["NTLMv2", "Kerberos"]
    }
  }

  # Network firewall: restrict storage to the ACI subnet.
  # Enabled in two cases:
  #   1. Managed VNet mode (vnet_integrated = true, existing_subnet_id = null) —
  #      the managed subnet has Microsoft.Storage service endpoint (network.tf).
  #   2. Existing subnet mode (existing_subnet_id set, restrict_storage_to_vnet = true) —
  #      caller must add Microsoft.Storage to the existing subnet's service_endpoints
  #      before applying, otherwise the firewall will lock ACI out of storage.
  dynamic "network_rules" {
    for_each = (
      (var.vnet_integrated && var.existing_subnet_id == null) ||
      (var.existing_subnet_id != null && var.restrict_storage_to_vnet)
    ) ? [1] : []
    content {
      default_action             = "Deny"
      virtual_network_subnet_ids = [local.aci_subnet_id]
      bypass                     = ["AzureServices"]
    }
  }

  tags = local.common_tags
}

###############################################################################
# Single File Share — all Nexus persistent data
# Mounted at /nexus-data: blob store, OrientDB, config, logs.
###############################################################################
resource "azurerm_storage_share" "nexus_data" {
  name                 = "nexus-data"
  storage_account_name = azurerm_storage_account.main.name
  quota                = var.nexus_data_share_quota_gb
}
