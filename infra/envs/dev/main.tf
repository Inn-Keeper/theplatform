terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
  cloud {
    organization = "theplatform"
    workspaces {
      name = "lambari-dev"
    }
  }
}

provider "azurerm" {
  features {}
  # CI identity is scoped to one resource group, so it can't register providers subscription-wide.
  resource_provider_registrations = "none"
}

module "app" {
  source = "../../modules/app"
  env    = "dev"
  # Bumped by the apply workflow on each Lambari release; revert the commit to roll back.
  image = "ghcr.io/inn-keeper/lambari-api:${trimspace(file("${path.module}/../../lambari.version"))}"
}

output "api_url" {
  value = module.app.api_url
}

output "web_url" {
  value = module.app.web_url
}

output "swa_deploy_token" {
  value     = module.app.swa_deploy_token
  sensitive = true
}
