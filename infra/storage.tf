# Discover the public IP of the machine running terraform so it can be added
# to the storage account firewall. Without this, creating the file share fails
# with 403 because the deny-all network rule blocks Terraform's data-plane calls.
data "http" "runner_ip" {
  url = "https://api.ipify.org"
}

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

  # Deny all by default; allow only:
  #   1. ACI subnet (via service endpoint) — for Nexus to read/write /nexus-data
  #   2. Runner's public IP              — so Terraform can create the file share
  network_rules {
    default_action             = "Deny"
    virtual_network_subnet_ids = [azurerm_subnet.aci.id]
    ip_rules                   = [chomp(data.http.runner_ip.response_body)]
    bypass                     = ["AzureServices"]
  }

  tags = local.common_tags
}

# Azure storage firewall rules take a few seconds to propagate after the
# storage account is created/updated.  Without this pause the file share
# creation hits the data-plane endpoint before the caller's IP is allowed,
# producing a 403.
resource "time_sleep" "storage_firewall_propagate" {
  depends_on      = [azurerm_storage_account.main]
  create_duration = "30s"
}

###############################################################################
# Single File Share — all Nexus persistent data
# Mounted at /nexus-data: blob store, OrientDB, config, logs.
###############################################################################
resource "azurerm_storage_share" "nexus_data" {
  depends_on           = [time_sleep.storage_firewall_propagate]
  name                 = "nexus-data"
  storage_account_name = azurerm_storage_account.main.name
  quota                = var.nexus_data_share_quota_gb
}
