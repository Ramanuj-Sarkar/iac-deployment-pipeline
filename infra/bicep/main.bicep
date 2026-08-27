@description('Environment name, used for naming and tagging (e.g. dev, staging, prod)')
param environmentName string = 'dev'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Postgres administrator login')
param dbAdminUsername string = 'appadmin'

@secure()
@description('Postgres administrator password')
param dbAdminPassword string

@description('Container image for the app. Leave empty on the first deployment — a public quickstart image is used so the Container App comes up healthy before the new ACR has anything in it. Then push your image and redeploy with this set to that reference.')
param containerImage string = ''

var namePrefix = 'iacdemo-${environmentName}'

// Stable per resource group, so redeploys reuse the same names. Keeps the
// globally-unique names (ACR, Key Vault, Postgres) from colliding with other
// deployments of this template.
var suffix = substring(uniqueString(resourceGroup().id), 0, 4)

var useAcr = !empty(containerImage)
var effectiveImage = useAcr ? containerImage : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace('${namePrefix}${suffix}acr', '-', '')
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${namePrefix}-${suffix}-kv'
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
  }
}

// User-assigned identity the Container App uses to pull the DB secret from
// Key Vault. User-assigned (not system-assigned) so it — and its role
// assignment — exist before the app that references the secret.
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-app-id'
  location: location
}

resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appIdentity.id, 'kv-secrets-user')
  scope: keyVault
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    // Key Vault Secrets User
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: '${namePrefix}-${suffix}-psql'
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: dbAdminUsername
    administratorLoginPassword: dbAdminPassword
    version: '16'
    storage: { storageSizeGB: 32 }
  }
}

resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: postgres
  name: 'appdb'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Demo-grade network opening: allow Azure-hosted services (the Container App)
// to reach Postgres. Production posture is VNet integration + private endpoint.
resource pgFirewallAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: postgres
  name: 'allow-azure-services'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Written through the ARM control plane, so — unlike the Terraform path — no
// data-plane Key Vault role assignment is needed for the deployer.
resource dbConnectionSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'database-url'
  properties: {
    value: 'postgresql://${dbAdminUsername}:${dbAdminPassword}@${postgres.properties.fullyQualifiedDomainName}:5432/${pgDatabase.name}?sslmode=require'
  }
}

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${namePrefix}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${namePrefix}-app'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appIdentity.id}': {}
    }
  }
  // Ordered after the role assignment. Propagation of the assignment still
  // races the container's secret pull, but Container Apps retries secret
  // resolution, and by the time this resource is reached the ~5-minute Postgres
  // create has already elapsed since kvSecretsUser. (Terraform makes the wait
  // explicit with a time_sleep; ARM has no clean equivalent without a
  // deployment script.)
  dependsOn: [kvSecretsUser]
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
      }
      // ACR credentials are only wired when pulling from the private registry.
      // The first deployment (public placeholder image) omits them.
      registries: useAcr ? [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ] : []
      secrets: concat(useAcr ? [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ] : [], [
        {
          // Resolved from Key Vault at runtime via the app's managed identity;
          // the connection string never lands in the image or the revision spec.
          name: 'database-url'
          keyVaultUrl: dbConnectionSecret.properties.secretUri
          identity: appIdentity.id
        }
      ])
    }
    template: {
      containers: [
        {
          name: 'app'
          image: effectiveImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

output acrLoginServer string = acr.properties.loginServer
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output keyVaultName string = keyVault.name
output usingPlaceholderImage bool = !useAcr
output nextImageRef string = '${acr.properties.loginServer}/todo-api:v1'
