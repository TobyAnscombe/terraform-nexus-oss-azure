###############################################################################
# Azure Container Group — Nexus OSS + nginx reverse proxy sidecar
#
# Two containers share localhost in the same ACI group:
#   nexus — sonatype/nexus3, listens on 8081 (internal only, not exposed)
#   nginx — nginx:1.27-alpine, listens on 80, proxies all traffic to localhost:8081
#
# Port 80 is the only externally exposed port. nginx writes its config inline
# via the commands override so no external config file or custom image is needed.
#
# ip_address_type and subnet_ids are conditional on var.vnet_integrated:
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

  # ---------------------------------------------------------------------------
  # Nexus OSS — internal on port 8081, not exposed externally
  # ---------------------------------------------------------------------------
  container {
    name   = "nexus"
    image  = "sonatype/nexus3:3.92.2"
    cpu    = var.nexus_cpu
    memory = var.nexus_memory_gb

    environment_variables = {
      # Use a fixed initial password ('admin123') rather than a random one
      # written to /nexus-data/admin.password.  Phase 2 (nexus/) sets the real
      # password via the datadrivers/nexus provider.
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

    # Probe via nginx (port 80) rather than directly to Nexus (8081) so that:
    # - no port 8081 declaration is needed on this container (avoids external exposure)
    # - probe tests the full proxy chain; a failed nginx config also triggers a restart
    liveness_probe {
      http_get {
        path   = "/service/rest/v1/status"
        port   = 80
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
  # nginx sidecar — proxies port 80 → localhost:8081
  # Config is written inline; containers share localhost so no network config needed.
  # client_max_body_size 0 allows arbitrarily large package uploads.
  # proxy_buffering off avoids buffering large package downloads in nginx memory.
  # ---------------------------------------------------------------------------
  container {
    name   = "nginx"
    image  = "nginx:1.27-alpine"
    cpu    = 0.1
    memory = 0.5

    ports {
      port     = 80
      protocol = "TCP"
    }

    # proxy_buffering off        — don't buffer responses (downloads) in nginx memory
    # proxy_request_buffering off — don't buffer request bodies (uploads) before forwarding;
    #                               prevents OOM on large package uploads (wheels, R tarballs)
    commands = [
      "/bin/sh", "-c",
      "echo 'server{listen 80;client_max_body_size 0;${local.nginx_ip_filter}location /{proxy_pass http://localhost:8081;proxy_set_header Host $host;proxy_set_header X-Real-IP $remote_addr;proxy_read_timeout 300;proxy_send_timeout 300;proxy_buffering off;proxy_request_buffering off;}}' > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'",
    ]

    liveness_probe {
      http_get {
        path   = "/service/rest/v1/status"
        port   = 80
        scheme = "Http"
      }
      initial_delay_seconds = 10
      period_seconds        = 30
      failure_threshold     = 5
      success_threshold     = 1
      timeout_seconds       = 10
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
