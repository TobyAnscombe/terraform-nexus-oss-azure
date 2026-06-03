###############################################################################
# Random suffix — keeps storage account names and DNS labels globally unique
###############################################################################
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

###############################################################################
# Resource Group
###############################################################################
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}
