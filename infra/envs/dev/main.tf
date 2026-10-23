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

# ponytail: placeholder until Lambari's image is on GHCR (step 4).
variable "image" {
  type    = string
  default = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "port" {
  type    = number
  default = 80
}

module "app" {
  source = "../../modules/app"
  env    = "dev"
  image  = var.image
  port   = var.port
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
