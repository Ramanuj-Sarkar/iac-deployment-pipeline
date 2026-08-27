output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "container_app_fqdn" {
  value = azurerm_container_app.main.ingress[0].fqdn
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}
