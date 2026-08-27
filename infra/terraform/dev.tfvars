environment_name  = "dev"
location          = "eastus"
db_admin_username = "appadmin"
container_image   = "myregistry.azurecr.io/app:latest"
# db_admin_password should come from a secret store / CI secret, not committed here
# cloudflare_zone_id = "your-zone-id"
