# ---------------------------------------------------------------------------
# Resource placement
# ---------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Name of the Azure Resource Group to create."
  type        = string
  default     = "rg-nexus-oss"
}

variable "location" {
  description = <<-EOF
    Azure region. Defaults to UK South.
    Other 'South' options: southcentralus, brazilsouth, southeastasia, australiasoutheast.
  EOF
  type        = string
  default     = "uksouth"
}

variable "environment" {
  description = "Short environment label used in resource names (dev | staging | prod)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------

variable "nexus_image" {
  description = "Nexus OSS container image. Pin to a specific tag; update here when upgrading."
  type        = string
  # renovate: datasource=docker
  default = "sonatype/nexus3:3.93.0"
}

variable "cloudflared_image" {
  description = "Cloudflare Tunnel sidecar image. Pin to a specific tag; check github.com/cloudflare/cloudflared/releases for the latest."
  type        = string
  # renovate: datasource=docker
  default = "cloudflare/cloudflared:2026.6.1"
}

# ---------------------------------------------------------------------------
# Container sizing
# ---------------------------------------------------------------------------

variable "nexus_cpu" {
  description = "vCPU cores for the Nexus container (minimum 1, recommended 2+)."
  type        = number
  default     = 2
}

variable "nexus_memory_gb" {
  description = "Memory in GB for the Nexus container (minimum 4, recommended 8 for production)."
  type        = number
  default     = 4
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

variable "storage_replication_type" {
  description = "Azure Storage Account replication type (LRS | GRS | ZRS | GZRS)."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "GRS", "ZRS", "GZRS"], var.storage_replication_type)
    error_message = "Must be LRS, GRS, ZRS, or GZRS."
  }
}

variable "nexus_data_share_quota_gb" {
  description = "Quota in GB for the Azure File Share that holds all Nexus data."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------
# Networking — VNet (always private; no public IP)
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the managed Virtual Network."
  type        = string
  default     = "10.100.0.0/16"
}

variable "aci_subnet_prefix" {
  description = "Address prefix for the ACI subnet within the VNet."
  type        = string
  default     = "10.100.1.0/24"
}

# ---------------------------------------------------------------------------
# Storage network access
# ---------------------------------------------------------------------------

variable "additional_storage_subnet_ids" {
  description = <<-EOF
    Resource IDs of existing subnets that should be allowed to access the
    Nexus storage account (e.g. a shared services VNet or dev workstation subnet).
    Each subnet must have the Microsoft.Storage service endpoint enabled.
    The ACI subnet is always included automatically.
  EOF
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Cloudflare Tunnel
# ---------------------------------------------------------------------------

variable "cloudflare_tunnel_token" {
  description = <<-EOF
    Cloudflare Tunnel token from Zero Trust dashboard (Networks → Tunnels).
    Create the tunnel first, then configure a Public Hostname ingress rule:
      <cloudflare_tunnel_hostname> → http://localhost:8081
    Paste the generated token here. Sensitive — never commit to source control.
  EOF
  type        = string
  sensitive   = true
}

variable "cloudflare_tunnel_hostname" {
  description = <<-EOF
    Public hostname configured in Cloudflare for this tunnel (e.g. nexus.example.com).
    Used as the nexus_base_url output that Phase 2 reads via remote state.
  EOF
  type        = string
}

