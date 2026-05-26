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
# Credentials
# ---------------------------------------------------------------------------

variable "admin_password" {
  description = <<-EOF
    Nexus admin password set during first-boot bootstrap.
    The container starts with default password 'admin123'
    (NEXUS_SECURITY_RANDOMPASSWORD=false); the bootstrap replaces it immediately.
    Must be ≥ 8 characters. SENSITIVE — never commit to source control.
  EOF
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 8
    error_message = "admin_password must be at least 8 characters."
  }
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
# Networking
# ---------------------------------------------------------------------------

variable "dns_name_label_prefix" {
  description = "Prefix for the container group's public DNS label. Full FQDN: <prefix>-<random>.<region>.azurecontainer.io"
  type        = string
  default     = "nexus-oss"
}

# ---------------------------------------------------------------------------
# VNet / private deployment
# ---------------------------------------------------------------------------

variable "vnet_integrated" {
  description = <<-EOF
    When false (default): ACI uses a public IP and DNS label — suitable for
    internet-accessible deployments.

    When true: ACI is deployed into snet-aci and receives a private IP only.
    The public IP and DNS label are removed. Requires:
      - A VPN Gateway or ExpressRoute peered to this VNet, OR a jumpbox in
        the VNet, so that terraform apply can reach the Nexus bootstrap API.
      - Update nsg_inbound_source to restrict access to your corporate CIDR.

    Changing this value forces replacement of the container group.
  EOF
  type        = bool
  default     = false
}

variable "vnet_address_space" {
  description = "Address space for the Virtual Network (always created, used by ACI when vnet_integrated = true)."
  type        = string
  default     = "10.100.0.0/16"
}

variable "aci_subnet_prefix" {
  description = "Address prefix for the ACI subnet within the VNet."
  type        = string
  default     = "10.100.1.0/24"
}

variable "nsg_inbound_source" {
  description = <<-EOF
    Source address prefix for the NSG inbound rule on port 8081.
    Default "*" = open to the internet (fine for public deployments).
    When going private, set to your corporate/VPN CIDR, e.g. "10.0.0.0/8".
  EOF
  type        = string
  default     = "*"
}
