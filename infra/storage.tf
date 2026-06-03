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

  # Network firewall: restrict storage to the managed ACI subnet when using the
  # built-in VNet (vnet_integrated = true, existing_subnet_id not set).
  # The managed subnet has Microsoft.Storage service endpoint (network.tf), which
  # is required for the subnet-based allowlist to work.
  #
  # When using an existing subnet (existing_subnet_id is set), this block is
  # skipped. Add Microsoft.Storage to that subnet's service_endpoints yourself,
  # then you can add a manual network rule via the Azure Portal or CLI.
  dynamic "network_rules" {
    for_each = (var.vnet_integrated && var.existing_subnet_id == null) ? [1] : []
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
