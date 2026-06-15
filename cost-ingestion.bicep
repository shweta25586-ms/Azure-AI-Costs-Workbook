@description('Location for resources')
param location string

@description('Name of your existing Log Analytics workspace')
param logAnalyticsWorkspaceName string

var dceName = 'dce-costdata-${uniqueString(resourceGroup().id)}'
var dcrName = 'dcr-costdata-${uniqueString(resourceGroup().id)}'
var tableName = 'AICostData_CL'
var streamName = 'Custom-${tableName}'

// Reference existing Log Analytics workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

// Data Collection Endpoint — receives ingestion calls
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Custom table in Log Analytics for AI cost data
resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalytics
  name: tableName
  properties: {
    schema: {
      name: tableName
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'BilledCost', type: 'real' }
        { name: 'ConsumedQuantity', type: 'real' }
        { name: 'UnitOfMeasure', type: 'string' }
        { name: 'UnitCost', type: 'real' }
        { name: 'ChargePeriodStart', type: 'dateTime' }
        { name: 'MeterName', type: 'string' }
        { name: 'Model', type: 'string' }
        { name: 'Direction', type: 'string' }
        { name: 'FoundryResource', type: 'string' }
        { name: 'Project', type: 'string' }
      ]
    }
    retentionInDays: 90
  }
}

// Data Collection Rule — routes ingested data to the custom table
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-AICostData_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'BilledCost', type: 'real' }
          { name: 'ConsumedQuantity', type: 'real' }
          { name: 'UnitOfMeasure', type: 'string' }
          { name: 'UnitCost', type: 'real' }
          { name: 'ChargePeriodStart', type: 'datetime' }
          { name: 'MeterName', type: 'string' }
          { name: 'Model', type: 'string' }
          { name: 'Direction', type: 'string' }
          { name: 'FoundryResource', type: 'string' }
          { name: 'Project', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalytics.id
          name: 'logAnalyticsDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'logAnalyticsDest' ]
        transformKql: 'source | project TimeGenerated, BilledCost, ConsumedQuantity, UnitOfMeasure, UnitCost, ChargePeriodStart, MeterName, Model, Direction, FoundryResource, Project'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [ table ]
}

output dceEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output dcrResourceId string = dcr.id
output streamName string = streamName
