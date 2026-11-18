// alerts.bicep
// Azure Monitor alert rules for the Azure SRE Agent VM demo.
//
// Azure SRE Agent polls Azure Monitor alerts directly (per Microsoft docs), so none of
// these alert rules reference an action group — they are standalone, enabled alert rules.
//
//   1. Log search alert  - error event count (Event table, Source == 'SREDemoApp', EventLevelName == 'Error') >= threshold over 5 min
//   2. Metric alert      - VM 'Percentage CPU' (Microsoft.Compute/virtualMachines) >= threshold, sustained over 5 min
//   3. Log search alert  - memory pressure (Perf table, CounterName == '% Committed Bytes In Use', ObjectName == 'Memory') average >= threshold over 5 min
//
// This module is deployed into the same resource group as the Log Analytics Workspace and the VM.

@description('Azure region for the log search alert rules. Should match the Log Analytics Workspace region. Metric alerts are deployed as "global" regardless of this value.')
param location string

@description('Resource ID of the Log Analytics Workspace (output of monitoring.bicep) that the log search alerts query.')
param logAnalyticsWorkspaceId string

@description('Full resource ID of the VM (created by the networking/VM module) that the CPU metric alert targets.')
param vmResourceId string

@description('Windows Event Log source name written by the demo app (must match the registered EventLog source name exactly, and the monitoring.bicep eventSourceName).')
param eventSourceName string = 'SREDemoApp'

@description('Number of Error-level SREDemoApp events within the 5-minute window that triggers the error-count alert.')
param errorCountThreshold int = 10

@description('CPU percentage (sustained average over 5 minutes) that triggers the CPU metric alert.')
param cpuThresholdPercentage int = 50

@description('Memory "% Committed Bytes In Use" percentage (average over 5 minutes) that triggers the memory log search alert.')
param memoryThresholdPercentage int = 70

@description('Name of the error-count log search alert rule.')
param errorCountAlertName string = 'alert-sre-demo-error-count'

@description('Name of the CPU metric alert rule.')
param cpuAlertName string = 'alert-sre-demo-cpu-high'

@description('Name of the memory log search alert rule.')
param memoryAlertName string = 'alert-sre-demo-memory-high'

// NOTE: timeAggregation 'Count' counts the ROWS returned by the query, not an aggregated value.
// This query must return one row per matching event (no `summarize count()`) so the raw event
// count is what gets compared against the threshold.
var errorCountQuery = 'Event | where EventLevelName == "Error" and Source == "${eventSourceName}"'
var memoryQuery = 'Perf | where ObjectName == "Memory" and CounterName == "% Committed Bytes In Use" | summarize AggregatedValue = avg(CounterValue)'

resource errorCountAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: errorCountAlertName
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: errorCountAlertName
    description: 'Fires when SREDemoApp writes ${errorCountThreshold}+ Error-level events to the Application event log within a 5-minute window.'
    severity: 2
    enabled: true
    scopes: [
      logAnalyticsWorkspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: errorCountQuery
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: errorCountThreshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
  }
}

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: cpuAlertName
  location: 'global'
  properties: {
    description: 'Fires when VM CPU utilization is sustained at or above ${cpuThresholdPercentage}% for 5 minutes.'
    severity: 3
    enabled: true
    scopes: [
      vmResourceId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'HighCpu'
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThanOrEqual'
          threshold: cpuThresholdPercentage
          timeAggregation: 'Average'
        }
      ]
    }
    autoMitigate: true
  }
}

resource memoryAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: memoryAlertName
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: memoryAlertName
    description: 'Fires when VM memory "% Committed Bytes In Use" averages at or above ${memoryThresholdPercentage}% over a 5-minute window.'
    severity: 3
    enabled: true
    scopes: [
      logAnalyticsWorkspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: memoryQuery
          timeAggregation: 'Average'
          metricMeasureColumn: 'AggregatedValue'
          operator: 'GreaterThanOrEqual'
          threshold: memoryThresholdPercentage
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
  }
}

@description('Resource ID of the error-count log search alert rule.')
output errorCountAlertId string = errorCountAlert.id

@description('Resource ID of the CPU metric alert rule.')
output cpuAlertId string = cpuAlert.id

@description('Resource ID of the memory log search alert rule.')
output memoryAlertId string = memoryAlert.id
