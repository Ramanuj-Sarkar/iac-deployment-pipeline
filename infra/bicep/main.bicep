@description('Environment name, used for naming and tagging (e.g. dev, staging, prod)')
param environmentName string = 'dev'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Postgres administrator login')
param dbAdminUsername string = 'appadmin'

@secure()
@description('Postgres administrator password')
param dbAdminPassword string

@description('Container image to deploy, e.g. myregistry.azurecr.io/app:latest')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

var namePrefix = 'iacdemo-${environmentName}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace('${namePrefix}acr', '-', '')
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${namePrefix}-kv'
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
  name: '${namePrefix}-psql'
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
  dependsOn: [kvSecretsUser]
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
        {
          // Resolved from Key Vault at runtime via the app's managed identity;
          // the connection string never lands in the image or the revision spec.
          name: 'database-url'
          keyVaultUrl: dbConnectionSecret.properties.secretUri
          identity: appIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
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
