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
  description = <<-EOT
    Container image for the app. Leave empty on the first apply — the config
    falls back to a public quickstart image so the Container App comes up
    healthy before the new ACR has anything in it. Then push your image (see
    the `push_command` output) and set this to that reference and re-apply.
  EOT
  type        = string
  default     = ""
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
