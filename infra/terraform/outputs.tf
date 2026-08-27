output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "container_app_fqdn" {
  value = azurerm_container_app.main.ingress[0].fqdn
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "using_placeholder_image" {
  description = "True while the app runs the public quickstart image (container_image unset)."
  value       = !local.image_in_acr
}

output "push_command" {
  description = "Phase 2: build the app image, push it to the new ACR, then set container_image to the printed reference and re-apply."
  value       = <<-EOT
    az acr login --name ${azurerm_container_registry.main.name}
    docker build -t ${azurerm_container_registry.main.login_server}/todo-api:v1 ../../app
    docker push ${azurerm_container_registry.main.login_server}/todo-api:v1
    # then: terraform apply -var-file=dev.tfvars -var="container_image=${azurerm_container_registry.main.login_server}/todo-api:v1"
  EOT
}
