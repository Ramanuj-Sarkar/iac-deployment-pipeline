terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # In real use, configure a remote backend (azurerm storage account) so
  # state isn't kept locally:
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstatestorage"
  #   container_name       = "tfstate"
  #   key                  = "iacdemo.tfstate"
  # }
}

provider "azurerm" {
  features {
    key_vault {
      # So `terraform destroy` actually purges the vault instead of leaving it
      # in soft-delete, where its globally-unique name would block the next
      # `apply` for 90 days.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

# The Cloudflare provider validates its config even when no DNS record is
# managed (cloudflare_zone_id unset -> cloudflare_record has count 0), so a
# token must always be present. The placeholder default is never used for a
# real API call; override it only when you actually set cloudflare_zone_id.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Short random suffix so the globally-unique resource names (ACR, Key Vault,
# Postgres) don't collide with other clones of this repo or with a prior
# soft-deleted vault of the same name.
resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  name_prefix = "iacdemo-${var.environment_name}"
  suffix      = random_string.suffix.result

  # Falls back to a public quickstart image so the very first `apply` produces a
  # healthy Container App before any image exists in the new ACR. Set
  # `container_image` (to the value in the `push_command` output) and re-apply.
  container_image = var.container_image != "" ? var.container_image : "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
  image_in_acr    = var.container_image != ""
}

resource "azurerm_resource_group" "main" {
  name     = "${local.name_prefix}-rg"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name_prefix}-logs"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_registry" "main" {
  name                = replace("${local.name_prefix}${local.suffix}acr", "-", "")
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "azurerm_key_vault" "main" {
  name                      = "${local.name_prefix}-${local.suffix}-kv"
  resource_group_name       = azurerm_resource_group.main.name
  location                  = azurerm_resource_group.main.location
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  enable_rbac_authorization = true
}

data "azurerm_client_config" "current" {}

# The identity running `terraform apply` needs data-plane access to write the
# connection-string secret (the vault uses RBAC, not access policies).
resource "azurerm_role_assignment" "deployer_kv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# User-assigned identity for the Container App. Using user-assigned (rather
# than system-assigned) breaks the create-order cycle: the identity and its
# Key Vault role assignment exist before the app that references the secret.
resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name_prefix}-app-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "app_kv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Azure AD role assignments take up to a few minutes to propagate. Ordering via
# depends_on isn't enough on its own — the first apply otherwise fails with a
# 403 when the data-plane secret write (and the Container App's secret pull)
# race ahead of propagation.
resource "time_sleep" "wait_for_kv_role_propagation" {
  depends_on = [
    azurerm_role_assignment.deployer_kv_secrets,
    azurerm_role_assignment.app_kv_secrets,
  ]
  create_duration = "60s"
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "${local.name_prefix}-${local.suffix}-psql"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "16"
  administrator_login    = var.db_admin_username
  administrator_password = var.db_admin_password
  storage_mb             = 32768
  sku_name               = "B_Standard_B1ms"
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "appdb"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Demo-grade network opening: let Azure-hosted services (the Container App)
# reach Postgres. Production posture is VNet integration + a private endpoint
# (see README "next steps").
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_key_vault_secret" "db_connection" {
  name         = "database-url"
  key_vault_id = azurerm_key_vault.main.id
  value        = "postgresql://${var.db_admin_username}:${var.db_admin_password}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.app.name}?sslmode=require"

  depends_on = [time_sleep.wait_for_kv_role_propagation]
}

resource "azurerm_container_app_environment" "main" {
  name                       = "${local.name_prefix}-env"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
}

resource "azurerm_container_app" "main" {
  name                         = "${local.name_prefix}-app"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Only wire ACR credentials once we're actually pulling from the private
  # registry. On the first apply (public placeholder image) these are omitted.
  dynamic "registry" {
    for_each = local.image_in_acr ? [1] : []
    content {
      server               = azurerm_container_registry.main.login_server
      username             = azurerm_container_registry.main.admin_username
      password_secret_name = "acr-password"
    }
  }

  dynamic "secret" {
    for_each = local.image_in_acr ? [1] : []
    content {
      name  = "acr-password"
      value = azurerm_container_registry.main.admin_password
    }
  }

  # Pulled from Key Vault at runtime using the app's managed identity —
  # the connection string is never baked into the image or the revision.
  secret {
    name                = "database-url"
    key_vault_secret_id = azurerm_key_vault_secret.db_connection.id
    identity            = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "app"
      image  = local.container_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
    }
  }

  depends_on = [time_sleep.wait_for_kv_role_propagation]
}

# Multi-provider example: point a Cloudflare DNS record at the app,
# something Bicep/ARM has no native way of doing in the same deployment.
resource "cloudflare_record" "app" {
  count   = var.cloudflare_zone_id != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.environment_name
  type    = "CNAME"
  content = azurerm_container_app.main.ingress[0].fqdn
  proxied = true
}
