# Requires Microsoft.Graph.Authentication
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All'

$pattern = @(
    'LocalUsersAndGroups'
    'RestrictedGroups'
    'ConfigureGroupMembership'
    'Local user group membership'
    'S-1-5-32-544'                 # Built-in Administrators group SID
) -join '|'

function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()

    do {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri

        foreach ($item in @($page.value)) {
            $items.Add($item)
        }

        $Uri = $page.'@odata.nextLink'
    } while ($Uri)

    return $items
}

$results = [System.Collections.Generic.List[object]]::new()

# 1. Settings Catalog and modern endpoint-security policies
$policies = Get-GraphCollection `
    'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'

foreach ($policy in $policies) {
    $settings = Get-GraphCollection (
        "https://graph.microsoft.com/beta/deviceManagement/" +
        "configurationPolicies/$($policy.id)/settings"
    )

    $content = @($policy, $settings) |
        ConvertTo-Json -Depth 100 -Compress

    if ($content -match $pattern) {
        $results.Add([pscustomobject]@{
            Source   = 'Configuration policy'
            Name     = $policy.name
            Id       = $policy.id
            Template = $policy.templateReference.templateDisplayName
            Assigned = $policy.isAssigned
        })
    }
}

# 2. Legacy device configuration and custom OMA-URI profiles
$legacyPolicies = Get-GraphCollection `
    'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations'

foreach ($policy in $legacyPolicies) {
    $detail = Invoke-MgGraphRequest -Method GET -Uri (
        "https://graph.microsoft.com/beta/deviceManagement/" +
        "deviceConfigurations/$($policy.id)"
    )

    $content = $detail | ConvertTo-Json -Depth 100 -Compress

    if ($content -match $pattern) {
        $results.Add([pscustomobject]@{
            Source   = 'Legacy/custom profile'
            Name     = $detail.displayName
            Id       = $detail.id
            Template = $detail.'@odata.type'
            Assigned = $null
        })
    }
}

# 3. Older endpoint-security intent policies
$intents = Get-GraphCollection `
    'https://graph.microsoft.com/beta/deviceManagement/intents'

$templateCache = @{}

foreach ($intent in $intents) {
    if (-not $templateCache.ContainsKey($intent.templateId)) {
        try {
            $templateCache[$intent.templateId] =
                Invoke-MgGraphRequest -Method GET -Uri (
                    "https://graph.microsoft.com/beta/deviceManagement/" +
                    "templates/$($intent.templateId)"
                )
        }
        catch {
            $templateCache[$intent.templateId] = $null
        }
    }

    $settings = Get-GraphCollection (
        "https://graph.microsoft.com/beta/deviceManagement/" +
        "intents/$($intent.id)/settings"
    )

    $template = $templateCache[$intent.templateId]

    $content = @($intent, $template, $settings) |
        ConvertTo-Json -Depth 100 -Compress

    if ($content -match $pattern) {
        $results.Add([pscustomobject]@{
            Source   = 'Endpoint-security intent'
            Name     = $intent.displayName
            Id       = $intent.id
            Template = $template.displayName
            Assigned = $intent.isAssigned
        })
    }
}

$results |
    Sort-Object Source, Name, Id -Unique |
    Format-Table -AutoSize
