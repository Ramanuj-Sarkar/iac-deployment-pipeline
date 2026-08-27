# Todo API — same app, two IaC tools

A containerized **todo REST API** (Flask + PostgreSQL) deployed to Azure
Container Apps, provisioned two ways — once with Bicep, once with Terraform.
The app does real CRUD against Postgres, so the database and Key Vault wiring
in the infra is load-bearing, not decorative: the connection string lives in
Key Vault and is pulled at runtime through the container's managed identity.

## Repo layout

```
app/                Flask API, SQLAlchemy models, Alembic migrations, pytest suite
app/todoapi/        application package (factory, routes, db, config, schemas)
app/migrations/     Alembic migration for the todos table
infra/bicep/        Bicep template + parameters (ARM-native deployment)
infra/terraform/    Terraform config (HCL) targeting the same resources + Cloudflare DNS
.github/workflows/  app-ci (tests + image build), infra-plan (plan / what-if on PR)
```

## The API

| Method   | Path            | Notes                                              |
|----------|-----------------|----------------------------------------------------|
| `GET`    | `/health`       | Liveness + a real `SELECT 1` against Postgres      |
| `GET`    | `/`             | Service info / endpoint list                       |
| `GET`    | `/todos`        | List. `?completed=true|false`, `?limit=`, `?offset=` |
| `POST`   | `/todos`        | Create. Body: `{title, description?, completed?}`  |
| `GET`    | `/todos/<id>`   | Fetch one (404 if missing)                         |
| `PATCH`  | `/todos/<id>`   | Partial update                                     |
| `DELETE` | `/todos/<id>`   | Delete (204)                                       |

Request bodies are validated with Pydantic; unknown fields are rejected.
List responses are `{items, total, limit, offset}`.

```bash
curl -sX POST localhost:8000/todos -H 'content-type: application/json' \
  -d '{"title":"ship the portfolio piece","description":"CRUD + IaC"}'

curl -s 'localhost:8000/todos?completed=false'
curl -sX PATCH localhost:8000/todos/<id> -d '{"completed":true}' -H 'content-type: application/json'
```

## Local development

```bash
cd app
docker compose up --build          # api on :8000, postgres on :5432
curl localhost:8000/health         # {"status":"ok","database":"ok"}
```

The container entrypoint runs `alembic upgrade head` before starting gunicorn,
so the schema is created on first boot.

### Tests

```bash
cd app
docker compose run --rm tests      # pytest against a throwaway postgres
```

Or directly, against any reachable Postgres:

```bash
cd app
pip install -r requirements-dev.txt
export DATABASE_URL=postgresql://appuser:apppass@localhost:5432/appdb
pytest
```

The suite applies the Alembic migration (and checks it downgrades cleanly),
then exercises every endpoint including validation and 404 paths.

### Migrations

```bash
cd app
export DATABASE_URL=...            # must be set; Alembic reads it directly
alembic revision --autogenerate -m "add due_date"
alembic upgrade head
```

`migrations/env.py` normalizes the URL (psycopg 3 driver, `sslmode=require`
for Azure hosts) the same way the app does.

## What gets provisioned (both tools)

- Resource group, Log Analytics workspace
- Azure Container Registry (ACR)
- Azure Container Apps environment + app
- Azure Database for PostgreSQL flexible server, with an `appdb` database and a
  firewall rule allowing Azure services (demo-grade; see next steps)
- Key Vault holding the DB connection string as the `database-url` secret
- A **user-assigned managed identity** for the container app, granted
  *Key Vault Secrets User* on the vault
- The container app's `DATABASE_URL` env var wired to a secret that references
  `database-url` in Key Vault **by identity** — the connection string is never
  in the image, the revision spec, or Terraform/Bicep output

User-assigned (rather than system-assigned) identity is deliberate: it and its
role assignment exist before the container app that consumes the secret, so a
single `apply` / `deployment` succeeds without a create-order cycle.

## Why both tools

Bicep is the ARM-native path: no external state file, first-class `what-if`
diffing, and — relevant here — it writes the Key Vault secret through the ARM
control plane, so the deployer needs no data-plane role on the vault.

Terraform writes that same secret through the Key Vault **data plane**, so the
config also assigns *Key Vault Secrets Officer* to the caller. In exchange,
Terraform composes across providers: it manages a Cloudflare DNS `CNAME`
pointing at the app in the same apply, which ARM/Bicep can't do natively. That
trade-off is the actual reason teams pick one over the other.

The Cloudflare DNS record is opt-in: leave `cloudflare_zone_id` unset and no
record is managed (the `cloudflare_api_token` variable keeps its placeholder
default so the provider still initializes). To enable it, set `cloudflare_zone_id`
and pass a real token via `TF_VAR_cloudflare_api_token`.

## Deploying

Prereqs: `az login` (the deployer needs **Owner** or **User Access
Administrator** — the stacks create role assignments), and a DB admin password
that satisfies the Postgres policy (8–128 chars, 3 of upper/lower/digit/symbol,
not containing the login). Generate one and keep it out of git:

```bash
export DB_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9_.-' < /dev/urandom | head -c 32)Aa1"
```

Deployment is **two phases**: stand up the infra with a public placeholder
image, then push the real image to the freshly-created ACR and point the app
at it. Resource names get a short random/`uniqueString` suffix, so parallel
clones of this repo don't collide on the globally-unique ACR / Key Vault /
Postgres names.

### Terraform

```bash
cd infra/terraform
export TF_VAR_db_admin_password="$DB_PASSWORD"

# phase 1 — infra + placeholder image
terraform init
terraform apply -var-file=dev.tfvars

# phase 2 — build, push, cut the app over (uses the `push_command` output)
terraform output -raw push_command | sh   # or run the printed commands by hand
```

Tear down with `terraform destroy` — the provider is configured to purge the
Key Vault so its name is reusable immediately.

### Bicep

```bash
az group create -n iacdemo-dev-rg -l eastus

# phase 1
az deployment group create -g iacdemo-dev-rg \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/main.dev.parameters.json \
  --parameters dbAdminPassword="$DB_PASSWORD"

# phase 2 — push, then redeploy with the image ref from the nextImageRef output
IMG=$(az deployment group show -g iacdemo-dev-rg -n main --query properties.outputs.nextImageRef.value -o tsv)
az acr login -n "${IMG%%.*}"
docker build -t "$IMG" app && docker push "$IMG"
az deployment group create -g iacdemo-dev-rg \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/main.dev.parameters.json \
  --parameters dbAdminPassword="$DB_PASSWORD" containerImage="$IMG"
```

After `az group delete`, the Key Vault lingers in soft-delete under its old
name for 90 days; the `uniqueString` suffix changes with the new resource
group, so a fresh deploy still succeeds. To reclaim the exact name:
`az keyvault purge --name <vault-name>`.

CI runs `terraform plan` and `az deployment group what-if` on every pull
request touching `infra/`, and `app-ci` runs the pytest suite and a Docker
build on every change to `app/`.

## Notes / next steps

- Remote Terraform backend (azurerm storage account) instead of local state.
- VNet integration + private endpoints for Postgres and Key Vault; drop the
  "allow Azure services" firewall rule.
- Split `dev` / `staging` / `prod` parameter files and gate `prod` behind a
  manual approval.
- Add auth (the API is currently unauthenticated) and per-user todo scoping.
