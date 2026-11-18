// monitoring.bicep
// Observability pipeline for the Azure SRE Agent VM demo:
//   - Log Analytics Workspace
//   - Data Collection Endpoint (DCE)
//   - Data Collection Rule (DCR): Windows Event Log (Application, Error-level, source SREDemoApp) + Perf counters (CPU, Memory)
//   - Data Collection Rule Association (DCR -> VM)
//   - Azure Monitor Agent VM extension
//
// This module is deployed into the same resource group as the VM (resource-group scope).
// The VM itself is created by a separate module (vm.bicep) and its resource ID/name are
// passed in as parameters so this module has no direct dependency on that module's internals.

@description('Azure region for all resources in this module.')
param location string

@description('Name of the Log Analytics Workspace to create.')
param logAnalyticsWorkspaceName string

@description('Data retention in days for the Log Analytics Workspace.')
param logAnalyticsRetentionInDays int = 30

@description('Name for the Data Collection Endpoint.')
param dataCollectionEndpointName string = 'dce-sre-agent-demo'

@description('Name for the Data Collection Rule.')
param dataCollectionRuleName string = 'dcr-sre-agent-demo'

@description('Full resource ID of the VM (created by the networking/VM module) that this DCR will be associated with and that will receive the Azure Monitor Agent extension.')
param vmResourceId string

@description('Name of the VM (must be the VM referenced by vmResourceId, and must reside in the same resource group this module deploys into).')
param vmName string

@description('Windows Event Log source name written by the demo app (must match the registered EventLog source name exactly).')
param eventSourceName string = 'SREDemoApp'

@description('Sampling frequency, in seconds, for the performance counters collected by the DCR.')
param perfCounterSamplingFrequencyInSeconds int = 60

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logAnalyticsRetentionInDays
  }
}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dataCollectionEndpointName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    dataSources: {
      windowsEventLogs: [
        {
          name: 'sreDemoAppErrorEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!*[System[Provider[@Name=\'${eventSourceName}\'] and (Level=2)]]'
          ]
        }
      ]
      performanceCounters: [
        {
          name: 'sreDemoAppPerfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: perfCounterSamplingFrequencyInSeconds
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\% Committed Bytes In Use'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'logAnalyticsDestination'
          workspaceResourceId: logAnalyticsWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
      }
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'dcra-sre-agent-demo'
  scope: vm
  properties: {
    dataCollectionRuleId: dataCollectionRule.id
  }
}

resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.22'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

@description('Resource ID of the Log Analytics Workspace.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

@description('Customer ID (workspace GUID) of the Log Analytics Workspace.')
output logAnalyticsWorkspaceCustomerId string = logAnalyticsWorkspace.properties.customerId

@description('Resource ID of the Data Collection Rule.')
output dataCollectionRuleId string = dataCollectionRule.id

@description('Resource ID of the VM that the DCR association and Azure Monitor Agent extension were applied to (echoed from the vmResourceId input for caller verification).')
output monitoredVmResourceId string = vmResourceId
