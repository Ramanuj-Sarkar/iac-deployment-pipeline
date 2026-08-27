environment_name  = "dev"
location          = "eastus"
db_admin_username = "appadmin"
container_image   = "myregistry.azurecr.io/app:latest"
# db_admin_password should come from a secret store / CI secret, not committed here
# For the optional Cloudflare DNS record, set both of these — the token via
# TF_VAR_cloudflare_api_token (a secret), not here:
# cloudflare_zone_id = "your-zone-id"
