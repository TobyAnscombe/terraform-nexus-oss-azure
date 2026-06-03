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

variable "existing_subnet_id" {
  description = <<-EOF
    Full Azure resource ID of an existing subnet to deploy the ACI container into.
    Use this to attach Nexus to an existing hub-and-spoke or spoke VNet rather than
    creating a dedicated VNet.

    When set:
      - The managed VNet, subnet, and NSG created by this module are NOT provisioned.
      - ACI receives a private IP from the provided subnet (vnet_integrated mode
        is implied — no public IP or DNS label is assigned).
      - You are responsible for NSG rules on the subnet: port 8081 must be open
        from any source that needs to reach Nexus (pip clients, CI runners, etc.).
      - The subnet must already be delegated to
        Microsoft.ContainerInstance/containerGroups.
      - terraform apply must be run from a host that can reach the private IP
        (e.g. a machine on the VPN / in the VNet).
      - The storage-account network firewall (restrict_to_vnet) is NOT applied
        automatically because this module does not manage the existing subnet's
        service endpoints. Add Microsoft.Storage to the subnet's service_endpoints
        manually and set restrict_storage_to_vnet = true to enable it.

    Example:
      /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet-nexus
  EOF
  type        = string
  default     = null
}

variable "vnet_integrated" {
  description = <<-EOF
    When false (default): ACI uses a public IP and DNS label — suitable for
    internet-accessible deployments.

    When true: ACI is deployed into the managed snet-aci subnet and receives a
    private IP only. The public IP and DNS label are removed. Requires:
      - A VPN Gateway or ExpressRoute peered to this VNet, OR a jumpbox in
        the VNet, so that terraform apply can reach the Nexus bootstrap API.
      - Update nsg_inbound_source to restrict access to your corporate CIDR.

    Ignored when existing_subnet_id is set (existing subnet implies VNet mode).
    Changing this value forces replacement of the container group.
  EOF
  type        = bool
  default     = false
}

variable "vnet_address_space" {
  description = "Address space for the managed Virtual Network. Ignored when existing_subnet_id is set."
  type        = string
  default     = "10.100.0.0/16"
}

variable "aci_subnet_prefix" {
  description = "Address prefix for the managed ACI subnet within the VNet. Ignored when existing_subnet_id is set."
  type        = string
  default     = "10.100.1.0/24"
}

variable "nsg_inbound_source" {
  description = <<-EOF
    Source address prefix for the NSG inbound rule on port 8081.
    Only applies to the managed NSG (i.e. when existing_subnet_id is NOT set).
    Default "*" = open to the internet (fine for public deployments).
    When going private, set to your corporate/VPN CIDR, e.g. "10.0.0.0/8".
  EOF
  type        = string
  default     = "*"
}
