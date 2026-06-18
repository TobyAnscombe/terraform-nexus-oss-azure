###############################################################################
# Managed Network — VNet + ACI subnet + NSG
#
# Always provisioned. ACI is always deployed privately — no public IP.
# cloudflared connects outbound to Cloudflare's network, so no inbound ports
# are needed and the NSG denies all inbound traffic by default.
###############################################################################

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.environment}-nexus"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# ACI subnet — delegated to Microsoft.ContainerInstance/containerGroups.
# Microsoft.Storage service endpoint enables the storage account network rule
# to allow traffic from this subnet while blocking all other sources.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "aci" {
  name                 = "snet-aci"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aci_subnet_prefix]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# ---------------------------------------------------------------------------
# NSG — no inbound allow rules.
# cloudflared establishes outbound-only connections to Cloudflare's network;
# no inbound port needs to be open. Azure's default outbound rules allow all
# egress, which cloudflared and the PyPI/CRAN proxies require.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aci" {
  name                = "nsg-${var.environment}-aci-nexus"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "aci" {
  subnet_id                 = azurerm_subnet.aci.id
  network_security_group_id = azurerm_network_security_group.aci.id
}
