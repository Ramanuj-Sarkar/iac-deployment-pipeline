variable "environment_name" {
  description = "Environment name, used for naming and tagging (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "db_admin_username" {
  description = "Postgres administrator login"
  type        = string
  default     = "appadmin"
}

variable "db_admin_password" {
  description = "Postgres administrator password"
  type        = string
  sensitive   = true
}

variable "container_image" {
  description = "Container image to deploy, e.g. myregistry.azurecr.io/app:latest"
  type        = string
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the DNS record pointing at the app (optional - demonstrates multi-provider Terraform)"
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Required only when cloudflare_zone_id is set; the placeholder default lets the provider initialize when no DNS record is managed. Must be 40 alphanumeric chars to pass the provider's own validation."
  type        = string
  default     = "placeholdertokenplaceholdertokenplacehld"
  sensitive   = true
}
