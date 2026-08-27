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
  features {}
}

provider "cloudflare" {}

locals {
  name_prefix = "iacdemo-${var.environment_name}"
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
  name                = replace("${local.name_prefix}acr", "-", "")
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "azurerm_key_vault" "main" {
  name                       = "${local.name_prefix}-kv"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
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

resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "${local.name_prefix}-psql"
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

  depends_on = [azurerm_role_assignment.deployer_kv_secrets]
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

  registry {
    server               = azurerm_container_registry.main.login_server
    username             = azurerm_container_registry.main.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.main.admin_password
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
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
    }
  }

  depends_on = [azurerm_role_assignment.app_kv_secrets]
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
