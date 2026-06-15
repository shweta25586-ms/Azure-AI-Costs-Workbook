@description('Location for the workbook resource')
param location string

@description('Resource ID of the Application Insights instance')
param appInsightsId string

@description('Unique environment suffix for deterministic naming')
param envSuffix string

var workbookName = guid(resourceGroup().id, 'ai-cost-observatory-${envSuffix}')
var workbookDisplayName = 'AI Token Cost Dashboard'

// gpt-4.1 pricing (USD per 1M tokens)
var promptPricePerMillion = '2.00'
var completionPricePerMillion = '8.00'

var workbookContent = loadTextContent('./ai-cost-dashboard.json')
var workbookV2Content = loadTextContent('./ai-cost-dashboard-v2.json')
var workbookV3Content = loadTextContent('./ai-cost-dashboard-v3.json')
var workbookV4Content = loadTextContent('./ai-cost-dashboard-v4.json')
var workbookV5Content = loadTextContent('./ai-cost-dashboard-v5.json')

var workbookV2Name = guid(resourceGroup().id, 'ai-cost-observatory-v2b-${envSuffix}')
var workbookV2DisplayName = 'AI Cost Observatory v2'

var workbookV3Name = guid(resourceGroup().id, 'ai-cost-observatory-v3-${envSuffix}')
var workbookV3DisplayName = 'AI Cost Observatory v3 — Native Metrics'

var workbookV4Name = guid(resourceGroup().id, 'ai-cost-observatory-v4-${envSuffix}')
var workbookV4DisplayName = 'AI Cost Observatory v4 — Unified Cost & Usage'

var workbookV5Name = guid(resourceGroup().id, 'ai-cost-observatory-v5-${envSuffix}')
var workbookV5DisplayName = 'AI Cost Observatory v5 — Foundry Project Analytics'

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    category: 'workbook'
    sourceId: appInsightsId
    serializedData: workbookContent
    version: '1.0'
  }
  tags: {
    'hidden-title': workbookDisplayName
    promptPricePerMillion: promptPricePerMillion
    completionPricePerMillion: completionPricePerMillion
  }
}

resource workbookV2 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookV2Name
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookV2DisplayName
    category: 'workbook'
    sourceId: appInsightsId
    serializedData: workbookV2Content
    version: '2.0'
  }
  tags: {
    'hidden-title': workbookV2DisplayName
  }
}

resource workbookV3 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookV3Name
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookV3DisplayName
    category: 'workbook'
    sourceId: appInsightsId
    serializedData: workbookV3Content
    version: '3.0'
  }
  tags: {
    'hidden-title': workbookV3DisplayName
  }
}

resource workbookV4 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookV4Name
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookV4DisplayName
    category: 'workbook'
    sourceId: appInsightsId
    serializedData: workbookV4Content
    version: '4.0'
  }
  tags: {
    'hidden-title': workbookV4DisplayName
  }
}

resource workbookV5 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookV5Name
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookV5DisplayName
    category: 'workbook'
    sourceId: appInsightsId
    serializedData: workbookV5Content
    version: '5.0'
  }
  tags: {
    'hidden-title': workbookV5DisplayName
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.properties.displayName
output workbookV2Id string = workbookV2.id
output workbookV2Name string = workbookV2.properties.displayName
output workbookV3Id string = workbookV3.id
output workbookV3Name string = workbookV3.properties.displayName
output workbookV4Id string = workbookV4.id
output workbookV4Name string = workbookV4.properties.displayName
output workbookV5Id string = workbookV5.id
output workbookV5Name string = workbookV5.properties.displayName
