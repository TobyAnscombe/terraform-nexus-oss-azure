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

  # Network firewall: when VNet-integrated, restrict storage access to the ACI
  # subnet so the account is not reachable from the public internet.
  # Requires Microsoft.Storage service endpoint on snet-aci (set in network.tf).
  #
  # When vnet_integrated = false (public mode) the block is omitted — ACI reaches
  # storage over the internet using the storage account key, which is the standard
  # ACI public-mode pattern.
  dynamic "network_rules" {
    for_each = var.vnet_integrated ? [1] : []
    content {
      default_action             = "Deny"
      virtual_network_subnet_ids = [azurerm_subnet.aci.id]
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
