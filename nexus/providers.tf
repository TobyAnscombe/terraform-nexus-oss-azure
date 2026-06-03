terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {}

  required_providers {
    nexus = {
      source  = "datadrivers/nexus"
      version = ">= 2.0.0"
    }
  }
}

# Read Phase 1 outputs — specifically nexus_base_url which only becomes
# available after the time_sleep.nexus_ready resource completes.
data "terraform_remote_state" "infra" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-nexus-tf-state"
    storage_account_name = var.state_storage_account
    container_name       = "tfstate"
    key                  = "infra.tfstate"
  }
}

provider "nexus" {
  url      = data.terraform_remote_state.infra.outputs.nexus_base_url
  username = "admin"
  password = var.admin_password
  insecure = true
}
