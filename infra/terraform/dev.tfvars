environment_name  = "dev"
location          = "eastus"
db_admin_username = "appadmin"

# container_image: leave unset for the first apply (a public placeholder image
# is used). After pushing to the ACR, pass it on the CLI — see the
# `push_command` output — rather than committing an image tag here.

# db_admin_password should come from a secret store / CI secret, not committed
# here. Pass it via TF_VAR_db_admin_password.

# For the optional Cloudflare DNS record, set cloudflare_zone_id here and pass
# the token via TF_VAR_cloudflare_api_token (a secret):
# cloudflare_zone_id = "your-zone-id"
