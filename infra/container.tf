###############################################################################
# Azure Container Group — Nexus OSS + cloudflared tunnel sidecar
#
# Two containers share localhost in the same ACI group:
#   nexus       — sonatype/nexus3, listens on 8081 (internal only)
#   cloudflared — cloudflare/cloudflared, connects outbound to Cloudflare's
#                 network and proxies traffic to localhost:8081
#
# No ports are exposed externally. ACI is always deployed with a private IP
# in the managed VNet. Public access is via the Cloudflare Tunnel only.
###############################################################################

resource "azurerm_container_group" "nexus" {
  name                = "aci-${var.environment}-nexus-oss"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  os_type         = "Linux"
  ip_address_type = "Private"
  subnet_ids      = [azurerm_subnet.aci.id]

  restart_policy = "Always"

  # ---------------------------------------------------------------------------
  # Nexus OSS — internal on port 8081
  # ---------------------------------------------------------------------------
  container {
    name   = "nexus"
    image  = var.nexus_image
    cpu    = var.nexus_cpu
    memory = var.nexus_memory_gb

    environment_variables = {
      # Use a fixed initial password ('admin123') rather than a random one
      # written to /nexus-data/admin.password.  Phase 2 (nexus/) sets the real
      # password via the datadrivers/nexus provider.
      NEXUS_SECURITY_RANDOMPASSWORD = "false"

      INSTALL4J_ADD_VM_PARAMS = local.nexus_jvm_opts
    }

    # Container-level port declaration for liveness probe — not exposed externally.
    ports {
      port     = 8081
      protocol = "TCP"
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

  # ---------------------------------------------------------------------------
  # cloudflared — Cloudflare Tunnel sidecar
  #
  # Connects outbound to Cloudflare's network using the tunnel token.
  # Routes all inbound tunnel traffic to localhost:8081 (Nexus), as configured
  # in the Cloudflare Zero Trust dashboard ingress rules.
  #
  # --no-autoupdate: prevents self-update attempts in a container environment.
  # TUNNEL_TOKEN:    read automatically by cloudflared when running 'tunnel run'.
  # ---------------------------------------------------------------------------
  container {
    name   = "cloudflared"
    image  = var.cloudflared_image
    cpu    = 0.25
    memory = 0.5

    secure_environment_variables = {
      TUNNEL_TOKEN = var.cloudflare_tunnel_token
    }

    commands = ["cloudflared", "tunnel", "--no-autoupdate", "run"]

    # Management API on localhost:2999 — /ready returns 200 when tunnel is up.
    ports {
      port     = 2999
      protocol = "TCP"
    }

    liveness_probe {
      http_get {
        path   = "/ready"
        port   = 2999
        scheme = "Http"
      }
      initial_delay_seconds = 10
      period_seconds        = 30
      failure_threshold     = 5
      timeout_seconds       = 5
    }
  }

  tags = local.common_tags
}

# Gate the nexus_base_url output until Nexus has had time to initialise its
# database.  Phase 2 reads this output via remote state; the depends_on ensures
# the nexus provider in nexus/ cannot be configured until this sleep completes.
resource "time_sleep" "nexus_ready" {
  depends_on      = [azurerm_container_group.nexus]
  create_duration = "2m"
}
