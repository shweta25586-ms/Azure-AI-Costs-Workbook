<#
.SYNOPSIS
    Ingests AI cost data into Log Analytics custom table (AICostData_CL).
.DESCRIPTION
    Two modes:
      - CostManagement (default): Queries Azure Cost Management for billed costs per account/model.
        Resolves project via ARM lookup (accurate for single-project accounts).
      - Metrics: Queries Azure Monitor Metrics API for InputTokens/OutputTokens per deployment,
        maps deployments to projects, and calculates cost using known per-token pricing.
        Gives true per-project attribution.
.PARAMETER SubscriptionId
    Azure subscription ID.
.PARAMETER DceEndpoint
    Data Collection Endpoint URI (from cost-ingestion.bicep output).
.PARAMETER DcrImmutableId
    Data Collection Rule immutable ID (from cost-ingestion.bicep output).
.PARAMETER Source
    Data source: CostManagement or Metrics.
.PARAMETER Timeframe
    Cost Management timeframe: MonthToDate, BillingMonthToDate, TheLastMonth,
    TheLastBillingMonth, or Custom (with StartDate/EndDate).
.PARAMETER StartDate
    Start date (yyyy-MM-dd). Used with Custom timeframe or Metrics source.
.PARAMETER EndDate
    End date (yyyy-MM-dd). Used with Custom timeframe or Metrics source.
#>
param(
    [string]$SubscriptionId = "3d806273-878a-46e4-885d-77f87a042979",
    [Parameter(Mandatory)][string]$DceEndpoint,
    [Parameter(Mandatory)][string]$DcrImmutableId,
    [string]$StreamName = "Custom-AICostData_CL",
    [ValidateSet("CostManagement","Metrics")]
    [string]$Source = "CostManagement",
    [ValidateSet("MonthToDate","BillingMonthToDate","TheLastMonth","TheLastBillingMonth","Custom")]
    [string]$Timeframe = "MonthToDate",
    [string]$StartDate,
    [string]$EndDate
)

$ErrorActionPreference = "Stop"

# --- Known pricing per 1K tokens (Global Standard, as of 2026) ---
$ModelPricing = @{
    'gpt-4.1'                 = @{ Input = 0.002;    Output = 0.008 }
    'gpt-4o'                  = @{ Input = 0.0025;   Output = 0.01 }
    'gpt-4o-mini'             = @{ Input = 0.00015;  Output = 0.0006 }
    'text-embedding-3-small'  = @{ Input = 0.00002;  Output = 0.0 }
    'text-embedding-3-large'  = @{ Input = 0.00013;  Output = 0.0 }
}

# --- Common: Get ARM token ---
$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
if (-not $armToken) { throw "Failed to get ARM access token. Run 'az login' first." }

if ($Source -eq "Metrics") {
    # =====================================================================
    # METRICS-BASED INGESTION: Per-project cost from Azure Monitor Metrics
    # =====================================================================
    Write-Host "=== Metrics-based ingestion (per-project) ==="

    # Determine time range
    if ($Timeframe -eq "Custom" -and $StartDate -and $EndDate) {
        $metricsStart = $StartDate
        $metricsEnd = $EndDate
    } else {
        $metricsStart = (Get-Date).ToString("yyyy-MM-01")
        $metricsEnd = (Get-Date).ToString("yyyy-MM-dd")
    }
    $timespan = "$metricsStart/$metricsEnd"
    Write-Host "Time range: $timespan"

    # 1. List all Foundry accounts
    Write-Host "Listing Foundry accounts..."
    $accountsResp = Invoke-RestMethod -Method Get `
        -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/accounts?api-version=2025-04-01-preview" `
        -Headers @{ "Authorization" = "Bearer $armToken" }
    $foundryAccounts = $accountsResp.value | Where-Object { $_.kind -in @('AIServices','OpenAI','CognitiveServices') }

    # 2. For each account, list projects and build account→project mapping, then list deployments
    $accountProjectMap = @{}  # accountName → projectName (for single-project accounts)
    $deploymentToProject = @{}  # deploymentName → @{ Account; Project; Model }

    foreach ($acct in $foundryAccounts) {
        $acctName = $acct.name
        $acctId = $acct.id

        # List projects for this account
        $projectName = 'no-project'
        try {
            $projResp = Invoke-RestMethod -Method Get `
                -Uri "https://management.azure.com$acctId/projects?api-version=2025-04-01-preview" `
                -Headers @{ "Authorization" = "Bearer $armToken" }
            $projects = @($projResp.value | ForEach-Object { ($_.name -split '/')[-1] })
            if ($projects.Count -eq 1) {
                $projectName = $projects[0]
            } elseif ($projects.Count -gt 1) {
                $projectName = "(shared: $($projects -join ', '))"
            }
            Write-Host "  $acctName → project: $projectName"
        } catch {
            Write-Host "  $acctName → (no project access)"
        }
        $accountProjectMap[$acctName] = $projectName

        # List deployments at account level
        try {
            $deplResp = Invoke-RestMethod -Method Get `
                -Uri "https://management.azure.com$acctId/deployments?api-version=2025-04-01-preview" `
                -Headers @{ "Authorization" = "Bearer $armToken" }
            foreach ($depl in $deplResp.value) {
                $deplName = ($depl.name -split '/')[-1]
                $modelName = $depl.properties.model.name
                $deploymentToProject[$deplName] = @{
                    Account = $acctName
                    Project = $projectName
                    Model   = if ($modelName) { $modelName } else { $deplName }
                }
            }
            Write-Host "    deployments: $(($deplResp.value | ForEach-Object { ($_.name -split '/')[-1] }) -join ', ')"
        } catch {
            Write-Host "    (no deployment access)"
        }
    }

    Write-Host "`nDeployment → Project mapping:"
    $deploymentToProject.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) → $($_.Value.Account)/$($_.Value.Project) (model: $($_.Value.Model))" }

    # 3. Query InputTokens/OutputTokens per deployment per day from Metrics API
    Write-Host "`nQuerying metrics per account..."
    $records = @()

    foreach ($acct in $foundryAccounts) {
        $acctName = $acct.name
        $acctId = $acct.id

        foreach ($direction in @('Input','Output')) {
            $metricName = "${direction}Tokens"
            try {
                $metricsResp = Invoke-RestMethod -Method Get `
                    -Uri "https://management.azure.com$acctId/providers/Microsoft.Insights/metrics?api-version=2024-02-01&metricnames=$metricName&timespan=$timespan&interval=P1D&`$filter=ModelDeploymentName eq '*'" `
                    -Headers @{ "Authorization" = "Bearer $armToken" }
            } catch {
                Write-Host "  $acctName/$metricName → no data"
                continue
            }

            foreach ($ts in $metricsResp.value[0].timeseries) {
                # Extract deployment name from metadata
                $deplName = ($ts.metadatavalues | Where-Object { $_.name.value -eq 'modeldeploymentname' }).value
                if (-not $deplName) { continue }

                # Use account→project mapping (we're already in this account's metrics)
                $project = $accountProjectMap[$acctName]
                if (-not $project) { $project = 'unknown' }
                # Model name = deployment name (deployment names match model names in this setup)
                $model = $deplName

                foreach ($dp in $ts.data) {
                    $tokenCount = $dp.total
                    if (-not $tokenCount -or $tokenCount -eq 0) { continue }

                    # Calculate cost from pricing table
                    $pricing = $ModelPricing[$model]
                    $pricePerK = if ($pricing) { $pricing[$direction] } else { 0.001 }  # fallback
                    $calculatedCost = [Math]::Round(($tokenCount / 1000) * $pricePerK, 8)
                    $unitCost = [Math]::Round($pricePerK, 8)

                    $records += [PSCustomObject]@{
                        TimeGenerated     = $dp.timeStamp
                        BilledCost        = $calculatedCost
                        ConsumedQuantity  = $tokenCount
                        UnitOfMeasure     = '1K'
                        UnitCost          = $unitCost
                        ChargePeriodStart = $dp.timeStamp
                        MeterName         = "$model ${direction}Tokens"
                        Model             = $model
                        Direction         = $direction
                        FoundryResource   = $acctName
                        Project           = $project
                    }
                }
            }
        }
    }

    Write-Host "`nParsed $($records.Count) metrics-based records."
    if ($records.Count -gt 0) {
        $records | Format-Table FoundryResource, Project, Model, Direction, BilledCost, ConsumedQuantity -AutoSize
    } else {
        Write-Host "No metrics data found. Ensure traffic has been routed through project deployments."
        return
    }

} else {
    # =====================================================================
    # COST MANAGEMENT-BASED INGESTION (original path)
    # =====================================================================
    Write-Host "=== Cost Management-based ingestion ==="
    Write-Host "Querying Cost Management for AI costs ($Timeframe)..."

    $dataset = @{
        granularity = "Daily"
    aggregation = @{
        totalCost = @{ name = "Cost"; function = "Sum" }
        totalQuantity = @{ name = "UsageQuantity"; function = "Sum" }
    }
    grouping = @(
        @{ type = "Dimension"; name = "MeterSubCategory" }
        @{ type = "Dimension"; name = "Meter" }
        @{ type = "Dimension"; name = "UnitOfMeasure" }
        @{ type = "Dimension"; name = "ResourceId" }
        @{ type = "Dimension"; name = "ResourceGroupName" }
    )
    filter = @{
        dimensions = @{
            name = "ServiceName"
            operator = "In"
            values = @(
                "Foundry Models",
                "Azure OpenAI Service",
                "Azure AI Services",
                "Cognitive Services",
                "Azure Machine Learning",
                "Azure AI Search",
                "Azure AI Agent Service"
            )
        }
    }
}

$body = @{
    type = "ActualCost"
    dataset = $dataset
}

if ($Timeframe -eq "Custom") {
    if (-not $StartDate -or -not $EndDate) { throw "StartDate and EndDate required for Custom timeframe." }
    $body.timeframe = "Custom"
    $body.timePeriod = @{ from = $StartDate; to = $EndDate }
} else {
    $body.timeframe = $Timeframe
}

$jsonBody = $body | ConvertTo-Json -Depth 10

$costResp = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $costResp = Invoke-RestMethod -Method Post `
            -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
            -Headers @{ "Authorization" = "Bearer $armToken"; "Content-Type" = "application/json" } `
            -Body $jsonBody
        break
    } catch {
        if ($_.Exception.Response.StatusCode -eq 429 -and $attempt -lt 5) {
            $wait = $attempt * 15
            Write-Host "Rate limited. Waiting $wait seconds (attempt $attempt/5)..."
            Start-Sleep -Seconds $wait
        } else { throw }
    }
}

if (-not $costResp.properties.rows -or $costResp.properties.rows.Count -eq 0) {
    Write-Host "No AI cost data found for timeframe '$Timeframe'."
    return
}

# --- 1b. Build Foundry account → projects mapping from ARM ---
Write-Host "Building Foundry account-to-project mapping..."

$accountsResp = Invoke-RestMethod -Method Get `
    -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/accounts?api-version=2025-04-01-preview" `
    -Headers @{ "Authorization" = "Bearer $armToken" }

# Filter to AI Services / OpenAI kind accounts (Foundry resources)
$foundryAccounts = $accountsResp.value | Where-Object { $_.kind -in @('AIServices','OpenAI','CognitiveServices') }

$projectMap = @{}  # account name → @(project names)
foreach ($acct in $foundryAccounts) {
    $acctName = $acct.name
    try {
        $projResp = Invoke-RestMethod -Method Get `
            -Uri "https://management.azure.com$($acct.id)/projects?api-version=2025-04-01-preview" `
            -Headers @{ "Authorization" = "Bearer $armToken" }
        # Project names come back as "accountName/projectName" — extract just the project part
        $projects = @($projResp.value | ForEach-Object { ($_.name -split '/')[-1] })
        $projectMap[$acctName] = $projects
        Write-Host "  $acctName → $($projects -join ', ')"
    } catch {
        Write-Host "  $acctName → (no projects or access denied)"
        $projectMap[$acctName] = @()
    }
}

# --- 2. Parse cost rows into records ---
# Dump column names for debugging
$colNames = $costResp.properties.columns | ForEach-Object { $_.name }
Write-Host "Columns: $($colNames -join ', ')"
Write-Host "Sample row: $($costResp.properties.rows[0] -join ' | ')"

$records = @()
foreach ($row in $costResp.properties.rows) {
    $cost = [double]$row[0]
    $usageQuantity = [double]$row[1]
    $usageDate = $row[2].ToString()
    $meterSubCat = $row[3]
    $meterName = $row[4]
    $unitOfMeasure = $row[5]
    $resourceId = if ($row.Count -gt 6) { $row[6] } else { '' }
    $resourceGroupName = if ($row.Count -gt 7) { $row[7] } else { '' }

    # Extract Foundry resource name and project from ResourceId
    # New Foundry: /subscriptions/.../providers/Microsoft.CognitiveServices/accounts/{account}/projects/{project}
    # Classic/no project: /subscriptions/.../providers/Microsoft.CognitiveServices/accounts/{account}
    $foundryResource = ''
    $project = 'unknown'
    if ($resourceId -match '/providers/Microsoft\.CognitiveServices/accounts/([^/]+)/projects/([^/]+)') {
        $foundryResource = $Matches[1]
        $project = $Matches[2]
    } elseif ($resourceId -match '/providers/Microsoft\.CognitiveServices/accounts/([^/]+)') {
        $foundryResource = $Matches[1]
        # Look up actual projects from ARM mapping
        $acctProjects = $projectMap[$foundryResource]
        if ($acctProjects -and $acctProjects.Count -eq 1) {
            # Single project — attribute directly
            $project = $acctProjects[0]
        } elseif ($acctProjects -and $acctProjects.Count -gt 1) {
            # Multiple projects — cannot split at cost level, mark as shared
            $project = "(shared: $($acctProjects -join ', '))"
        } else {
            $project = 'no-project'
        }
    } elseif ($resourceId -match '/([^/]+)$') {
        $foundryResource = $Matches[1]
        $project = 'unknown'
    }

    # Parse the unit multiplier from UnitOfMeasure (e.g., "1K" → 1000, "1M" → 1000000, "1" → 1)
    $unitMultiplier = switch -Regex ($unitOfMeasure) {
        '^\d+M$'  { [double]($unitOfMeasure -replace 'M$','') * 1000000; break }
        '^\d+K$'  { [double]($unitOfMeasure -replace 'K$','') * 1000; break }
        '^\d+$'   { [double]$unitOfMeasure; break }
        default   { 1 }
    }

    # Actual consumed tokens = UsageQuantity × unit multiplier
    $consumedTokens = [double]($usageQuantity * $unitMultiplier)

    # Unit cost = Cost / UsageQuantity (price per UnitOfMeasure block)
    $unitCost = if ($usageQuantity -gt 0) { [Math]::Round($cost / $usageQuantity, 8) } else { 0.0 }

    # Parse direction and model name generically from meter name.
    # Direction markers (longest-first to avoid partial matches):
    #   Input:  output, outpt, outp, opt, out
    #   Output: input, inpt, inp, in
    $dirPattern = '\b(output|outpt|outp|input|inpt|inp|opt|out|in)\b'
    $dirMatch = [regex]::Match($meterName, $dirPattern, 'IgnoreCase')
    if ($dirMatch.Success) {
        $dirToken = $dirMatch.Value.ToLower()
        if ($dirToken -in @('input','inpt','inp','in')) {
            $direction = 'Input'
        } else {
            $direction = 'Output'
        }
        # Model = everything before the direction marker, trimmed
        $modelRaw = $meterName.Substring(0, $dirMatch.Index).Trim()
    } else {
        $direction = 'Other'
        # No direction found — strip trailing unit/region tokens
        $modelRaw = $meterName -replace '\s*\d*[MK]?\s*Tokens.*$', ''
        $modelRaw = $modelRaw.Trim()
    }
    # Normalize: lowercase, whitespace to hyphens, collapse, trim dashes
    $model = $modelRaw.ToLower().Trim() -replace '[\s]+', '-' -replace '-{2,}', '-' -replace '^-|-$', ''
    # If model is empty (direction was the first word), use full meter stripped
    if (-not $model) {
        $model = ($meterName -replace '\s*\d*[MK]?\s*Tokens.*$', '' -replace '\b(gl|glbl)\b', '').ToLower().Trim() -replace '[\s]+', '-' -replace '-{2,}', '-' -replace '^-|-$', ''
    }

    # Parse date — Cost Management returns dates as numeric 20260508 or ISO string
    $dateStr = $usageDate
    if ($dateStr -match '^\d{8}$') {
        $dateStr = [datetime]::ParseExact($dateStr, 'yyyyMMdd', $null).ToString('o')
    }

    $records += [PSCustomObject]@{
        TimeGenerated     = $dateStr
        BilledCost        = $cost
        ConsumedQuantity  = $consumedTokens
        UnitOfMeasure     = $unitOfMeasure
        UnitCost          = $unitCost
        ChargePeriodStart = $dateStr
        MeterName         = $meterName
        Model             = $model
        Direction         = $direction
        FoundryResource   = $foundryResource
        Project           = $project
    }
}

Write-Host "Parsed $($records.Count) cost records."
$records | Format-Table FoundryResource, Project, Model, Direction, BilledCost, ConsumedQuantity, UnitOfMeasure, UnitCost, ChargePeriodStart -AutoSize

}  # end else (CostManagement path)

# --- 3. Push to Log Analytics via Logs Ingestion API ---
Write-Host "Pushing records to Log Analytics..."

$monitorToken = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
if (-not $monitorToken) { throw "Failed to get Monitor access token." }

# Convert to array of hashtables for JSON serialization (PS 5.1 compatible)
$jsonRecords = $records | ForEach-Object {
    @{
        TimeGenerated     = $_.TimeGenerated
        BilledCost        = $_.BilledCost
        ConsumedQuantity  = $_.ConsumedQuantity
        UnitOfMeasure     = $_.UnitOfMeasure
        UnitCost          = $_.UnitCost
        ChargePeriodStart = $_.ChargePeriodStart
        MeterName         = $_.MeterName
        Model             = $_.Model
        Direction         = $_.Direction
        FoundryResource   = $_.FoundryResource
        Project           = $_.Project
    }
}
$ingestBody = "[$( ($jsonRecords | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join ',' )]"
$ingestUri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"

Invoke-RestMethod -Method Post `
    -Uri $ingestUri `
    -Headers @{ "Authorization" = "Bearer $monitorToken"; "Content-Type" = "application/json" } `
    -Body $ingestBody

Write-Host "Successfully ingested $($records.Count) records into AICostData_CL."
