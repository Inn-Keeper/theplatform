# One-time bootstrap: per-env OIDC identities, resource groups, HCP workspaces,
# GitHub environments, and a subscription budget. Run locally; state stays local.
# ponytail: local state on purpose — this creates the remote backend everything else uses.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    github  = { source = "integrations/github", version = "~> 6.0" }
    tfe     = { source = "hashicorp/tfe", version = "~> 0.60" }
  }
}

variable "hcp_org" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "github_owner" {
  type    = string
  default = "Inn-Keeper"
}

variable "repo" {
  type    = string
  default = "theplatform"
}

variable "location" {
  type    = string
  default = "eastus"
}

locals {
  envs = toset(["dev", "prd"])
}

provider "azurerm" {
  features {}
}

provider "github" {
  owner = var.github_owner
}

provider "tfe" {
  organization = var.hcp_org
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "env" {
  for_each = local.envs
  name     = "rg-lambari-${each.key}"
  location = var.location
}

resource "azuread_application" "gh" {
  for_each     = local.envs
  display_name = "gh-${var.repo}-${each.key}"
}

resource "azuread_service_principal" "gh" {
  for_each  = local.envs
  client_id = azuread_application.gh[each.key].client_id
}

# Only workflow jobs running in this repo's matching GitHub Environment can assume the identity.
resource "azuread_application_federated_identity_credential" "gh" {
  for_each       = local.envs
  application_id = azuread_application.gh[each.key].id
  display_name   = "github-${each.key}"
  issuer         = "https://token.actions.githubusercontent.com"
  audiences      = ["api://AzureADTokenExchange"]
  subject        = "repo:${var.github_owner}/${var.repo}:environment:${each.key}"
}

# Least privilege: each identity can only touch its own resource group.
resource "azurerm_role_assignment" "gh" {
  for_each             = local.envs
  scope                = azurerm_resource_group.env[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.gh[each.key].object_id
}

resource "azurerm_consumption_budget_subscription" "guard" {
  name            = "free-tier-guard"
  subscription_id = data.azurerm_subscription.current.id
  amount          = 1
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-10-01T00:00:00Z"
  }

  notification {
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}

# State + locking only; plans/applies run in GitHub Actions.
resource "tfe_workspace" "env" {
  for_each = local.envs
  name     = "lambari-${each.key}"
}

resource "tfe_workspace_settings" "env" {
  for_each       = local.envs
  workspace_id   = tfe_workspace.env[each.key].id
  execution_mode = "local"
}

data "github_user" "me" {
  username = var.github_owner
}

resource "github_repository_environment" "env" {
  for_each    = local.envs
  repository  = var.repo
  environment = each.key

  dynamic "reviewers" {
    for_each = each.key == "prd" ? [1] : []
    content {
      users = [data.github_user.me.id]
    }
  }
}

# Identifiers, not secrets — safe as plain variables.
resource "github_actions_environment_variable" "azure" {
  for_each = {
    for pair in setproduct(local.envs, ["AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_SUBSCRIPTION_ID"]) :
    "${pair[0]}/${pair[1]}" => { env = pair[0], name = pair[1] }
  }
  repository    = var.repo
  environment   = github_repository_environment.env[each.value.env].environment
  variable_name = each.value.name
  value = {
    AZURE_CLIENT_ID       = azuread_application.gh[each.value.env].client_id
    AZURE_TENANT_ID       = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID = data.azurerm_subscription.current.subscription_id
  }[each.value.name]
}

output "client_ids" {
  value = { for e in local.envs : e => azuread_application.gh[e].client_id }
}
