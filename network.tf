###############################################################################
# Network — VNet + ACI subnet + NSG
#
# The VNet and subnet are ALWAYS created so the private-deployment path is
# ready whenever you need it.  ACI only joins the VNet when:
#
#   vnet_integrated = true   (in terraform.tfvars)
#
# When vnet_integrated = false (default):
#   - ACI keeps its public IP and DNS label.
#   - The VNet exists but is unused — no cost impact.
#   - NSG rules are present but don't affect the public-IP container.
#
# When vnet_integrated = true:
#   - ACI gets a private IP from snet-aci.
#   - The public IP and DNS label are removed.
#   - NSG rules apply.  Update nsg_inbound_source in terraform.tfvars to
#     restrict access to your VPN / ExpressRoute / peered VNet CIDR.
#   - Bootstrap (and all pip traffic) must come from a host that can reach
#     the private IP — run terraform apply from a machine on the VPN.
#
# Going private — step-by-step:
#   1. Connect your corporate network (VPN Gateway or ExpressRoute) to this VNet.
#   2. Set vnet_integrated       = true          in terraform.tfvars
#      Set nsg_inbound_source    = "10.x.x.x/y"  (your corporate CIDR)
#   3. Run terraform apply from a machine on the VPN.
#   4. Update pip.conf / CI runners to use the private IP output.
###############################################################################

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.environment}-nexus"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# ACI subnet — must be delegated to Microsoft.ContainerInstance/containerGroups
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "aci" {
  name                 = "snet-aci"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aci_subnet_prefix]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# ---------------------------------------------------------------------------
# NSG — controls inbound traffic when vnet_integrated = true
#
# Rule: allow port 8081 from nsg_inbound_source (default: * = open)
# To lock down: set nsg_inbound_source to your corporate CIDR in tfvars.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aci" {
  name                = "nsg-${var.environment}-aci-nexus"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  security_rule {
    name                       = "allow-nexus-8081-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8081"
    source_address_prefix      = var.nsg_inbound_source
    destination_address_prefix = "*"
  }

  # Outbound: Azure's default rules allow all outbound — needed for the
  # PyPI proxy to fetch packages from pypi.org and for ACI infrastructure.
}

resource "azurerm_subnet_network_security_group_association" "aci" {
  subnet_id                 = azurerm_subnet.aci.id
  network_security_group_id = azurerm_network_security_group.aci.id
}
