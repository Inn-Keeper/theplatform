# Lambari runtime for one environment: API on Container Apps, frontend on Static Web Apps.
# The resource group is created by bootstrap; this module only fills it.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

variable "env" {
  type = string
}

variable "image" {
  type = string
}

# Free subscriptions allow one Container Apps environment per region, so envs can't share one.
variable "location" {
  type    = string
  default = null # resource group's region
}

# Static Web Apps Free tier is only offered in a few regions.
variable "swa_location" {
  type    = string
  default = "eastus2"
}

data "azurerm_resource_group" "env" {
  name = "rg-lambari-${var.env}"
}

resource "azurerm_static_web_app" "web" {
  name                = "swa-lambari-${var.env}"
  resource_group_name = data.azurerm_resource_group.env.name
  location            = var.swa_location
  sku_tier            = "Free"
  sku_size            = "Free"

  # The deploy action stamps the source repo onto the site; not ours to manage.
  lifecycle {
    ignore_changes = [repository_url, repository_branch]
  }
}

# No Log Analytics workspace: keeps it free. Logs via `az containerapp logs show`.
resource "azurerm_container_app_environment" "env" {
  name                = "cae-lambari-${var.env}"
  resource_group_name = data.azurerm_resource_group.env.name
  location            = coalesce(var.location, data.azurerm_resource_group.env.location)

  # Azure adds this profile by default; declaring it stops a perpetual diff. Still free consumption billing.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "api" {
  name                         = "ca-lambari-api-${var.env}"
  resource_group_name          = data.azurerm_resource_group.env.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  ingress {
    external_enabled = true
    target_port      = 8080
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Scale to zero when idle: costs nothing, but in-memory state resets and the first request cold-starts.
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "api"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/api/health"
      }

      # Same demo limits as Lambari's render.yaml, sized for 0.5 GiB.
      env {
        name  = "LAMBARI_SIM_MAX_RATE"
        value = "1000"
      }
      env {
        name  = "LAMBARI_SIM_MAX_DURATION"
        value = "10m"
      }
      env {
        name  = "LAMBARI_DISABLE_INGEST"
        value = "true"
      }
      env {
        name  = "LAMBARI_ALLOWED_ORIGINS"
        value = "https://${azurerm_static_web_app.web.default_host_name}"
      }
    }
  }
}

output "api_url" {
  value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "web_url" {
  value = "https://${azurerm_static_web_app.web.default_host_name}"
}

# Used by Lambari's workflow to upload the frontend build.
output "swa_deploy_token" {
  value     = azurerm_static_web_app.web.api_key
  sensitive = true
}
