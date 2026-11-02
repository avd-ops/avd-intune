# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][string]$EntraManifestPath = './entra-manifest.json',
    [Parameter()][string]$OutputPath = './intune-manifest.json',
    [Parameter()][string]$RunManifestPath = './intune-run-manifest.json',
    [Parameter()][string]$ProfilesDirectory = '',
    [Parameter()][string]$Prefix = '',
    [Parameter()][switch]$DeployAssignmentFilters,
    [Parameter()][switch]$IncludeWin365,
    [Parameter()][switch]$DryRun,
    [Parameter()][scriptblock]$GraphInvoker
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StampedName {
    param(
        [Parameter(Mandatory)][string]$RawName,
        [Parameter(Mandatory)][string]$StampPrefix
    )
    if ($RawName -match '^\[avd-ops[^\]]*\]\s*(.+)$') {
        return "$StampPrefix $($Matches[1])"
    }
    return "$StampPrefix $RawName"
}

function ConvertTo-GraphSettingInstance {
    param(
        [Parameter(Mandatory)][object]$SettingNode
    )
    if ($null -ne $SettingNode.PSObject.Properties['settingInstance']) {
        return $SettingNode.settingInstance
    }

    $settingId = [string]$SettingNode.settingId
    $val = $SettingNode.value
    $childInstances = @()
    if ($null -ne $SettingNode.PSObject.Properties['children'] -and $null -ne $SettingNode.children) {
        foreach ($child in $SettingNode.children) {
            $childInstances += ConvertTo-GraphSettingInstance -SettingNode $child
        }
    }

    if ($val -is [int] -or $val -is [long] -or $val -is [double]) {
        return [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId = $settingId
            simpleSettingValue  = [ordered]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'
                value         = [int]$val
            }
        }
    }

    $strVal = [string]$val
    if ($settingId -like '*_multisz' -or $strVal.StartsWith('\\')) {
        return [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId = $settingId
            simpleSettingValue  = [ordered]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                value         = $strVal
            }
        }
    }

    return [ordered]@{
        '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
        settingDefinitionId = $settingId
        choiceSettingValue  = [ordered]@{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
            value         = $strVal
            children      = $childInstances
        }
    }
}

function ConvertTo-GraphConfigurationPolicyPayload {
    param(
        [Parameter(Mandatory)][object]$ProfileObject,
        [Parameter(Mandatory)][string]$StampedName
    )
    $graphSettings = @()
    foreach ($item in $ProfileObject.settings) {
        $instance = ConvertTo-GraphSettingInstance -SettingNode $item
        $graphSettings += [ordered]@{
            '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
            settingInstance = $instance
        }
    }

    $platforms = if ($null -ne $ProfileObject.PSObject.Properties['platforms']) { [string]$ProfileObject.platforms } else { 'windows10' }
    $technologies = if ($null -ne $ProfileObject.PSObject.Properties['technologies']) { [string]$ProfileObject.technologies } else { 'mdm' }
    $description = if ($null -ne $ProfileObject.PSObject.Properties['description']) { [string]$ProfileObject.description } else { '' }

    return [ordered]@{
        name         = $StampedName
        description  = $description
        platforms    = $platforms
        technologies = $technologies
        settings     = $graphSettings
    }
}

function Get-DeterministicDryRunId {
    param(
        [Parameter(Mandatory)][string]$Seed
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hex = -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][object]$Body = $null,
        [Parameter()][bool]$IsDryRun = $false,
        [Parameter()][scriptblock]$CustomInvoker = $null
    )
    if ($null -ne $CustomInvoker) {
        return (& $CustomInvoker $Method $Uri $Body)
    }

    if ($IsDryRun) {
        if ($Method -eq 'GET' -and $Uri -like '*/subscribedSkus*') {
            return [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        skuPartNumber    = 'SPE_E5'
                        capabilityStatus = 'Enabled'
                        servicePlans     = @(
                            [pscustomobject]@{
                                servicePlanName    = 'INTUNE_A'
                                provisioningStatus = 'Success'
                            }
                        )
                    }
                )
            }
        }
        if ($Method -eq 'GET' -and $Uri -like '*/deviceEnrollmentConfigurations*') {
            return [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        '@odata.type'      = '#microsoft.graph.deviceEnrollmentPlatformRestrictionsConfiguration'
                        id                 = '00000000-0000-0000-0000-000000000001'
                        displayName        = 'Default Enrollment Restrictions'
                        windowsRestriction = [pscustomobject]@{
                            platformBlocked                 = $false
                            personalDeviceEnrollmentBlocked = $false
                        }
                    }
                )
            }
        }
        if ($Method -eq 'GET') {
            return [pscustomobject]@{ value = @() }
        }
        if ($Method -eq 'POST' -and $Uri -notlike '*/assign') {
            $nameSeed = if ($null -ne $Body -and $null -ne $Body['name']) {
                [string]$Body['name']
            } elseif ($null -ne $Body -and $null -ne $Body['displayName']) {
                [string]$Body['displayName']
            } else {
                $Uri
            }
            return [pscustomobject]@{
                id = (Get-DeterministicDryRunId -Seed $nameSeed)
            }
        }
        return [pscustomobject]@{ status = 'ok' }
    }

    $azArgs = @('rest', '--method', $Method, '--uri', $Uri)
    $tempFile = $null
    try {
        if ($null -ne $Body) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            $jsonBody = $Body | ConvertTo-Json -Depth 20 -Compress
            [System.IO.File]::WriteAllText($tempFile, $jsonBody, [System.Text.UTF8Encoding]::new($false))
            $azArgs += @('--headers', 'Content-Type=application/json', '--body', "@$tempFile")
        }
        $rawOut = & az @azArgs
        if ($LASTEXITCODE -ne 0) {
            throw "az rest failed ($Method $Uri) with exit code $LASTEXITCODE"
        }
        if ([string]::IsNullOrWhiteSpace(($rawOut -join ''))) {
            return [pscustomobject]@{}
        }
        return (($rawOut -join "`n") | ConvertFrom-Json)
    } finally {
        if ($null -ne $tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-PythonExecutable {
    foreach ($candidate in @('python3', 'python')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Source -notlike '*\WindowsApps\*') {
            return $cmd.Source
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $wildcard = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\python.exe'
        $localPythons = @(Get-Item -Path $wildcard -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($localPythons.Count -gt 0) {
            return $localPythons[0].FullName
        }
    }
    foreach ($candidate in @('python3', 'python')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            return $cmd.Source
        }
    }
    throw 'Python 3 executable was not found.'
}

$isDryRun = $DryRun.IsPresent -or ($env:AVD_OPS_DRY_RUN -eq '1')

if (-not (Test-Path -LiteralPath $EntraManifestPath)) {
    throw "Entra handoff manifest not found at '$EntraManifestPath'."
}

$entraManifest = Get-Content -LiteralPath $EntraManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$environment = [string]$entraManifest.environment
if ($environment -notin @('dev', 'test', 'prod')) {
    throw "Invalid or missing environment '$environment' in '$EntraManifestPath'. Expected dev, test, or prod."
}

$resolvedPrefix = if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
    $Prefix.Trim()
} elseif ($null -ne $entraManifest.PSObject.Properties['prefix'] -and -not [string]::IsNullOrWhiteSpace([string]$entraManifest.prefix)) {
    ([string]$entraManifest.prefix).Trim()
} else {
    'avd'
}

if ($null -eq $entraManifest.PSObject.Properties['groups'] -or $null -eq $entraManifest.groups) {
    throw "Missing 'groups' object in '$EntraManifestPath'."
}

$targetDeviceGroupId = [string]$entraManifest.groups.sessionHostsDynamicGroupId
$avdUsersGroupId = [string]$entraManifest.groups.avdUsersGroupId

if ([string]::IsNullOrWhiteSpace($targetDeviceGroupId)) {
    throw "Missing 'groups.sessionHostsDynamicGroupId' in '$EntraManifestPath'."
}
if ([string]::IsNullOrWhiteSpace($avdUsersGroupId)) {
    throw "Missing 'groups.avdUsersGroupId' in '$EntraManifestPath'."
}

$resolvedProfilesDir = if (-not [string]::IsNullOrWhiteSpace($ProfilesDirectory)) {
    $ProfilesDirectory
} else {
    Join-Path $PSScriptRoot '../profiles'
}

$stampPrefix = "[avd-ops-$resolvedPrefix-$environment]"

if (-not $PSCmdlet.ShouldProcess("Microsoft Intune ($stampPrefix)", 'Deploy AVD Settings Catalog and compliance profiles')) {
    return
}

# 1. Preflight check: Intune licensing (read-only check; never purchases licenses)
$skusResponse = Invoke-GraphRequest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
$hasIntunePlan = $false
if ($null -ne $skusResponse -and $null -ne $skusResponse.PSObject.Properties['value']) {
    foreach ($sku in $skusResponse.value) {
        if ($sku.capabilityStatus -ne 'Enabled') {
            continue
        }
        foreach ($plan in $sku.servicePlans) {
            if ($plan.servicePlanName -like 'INTUNE_A*' -and $plan.provisioningStatus -eq 'Success') {
                $hasIntunePlan = $true
                break
            }
        }
        if ($hasIntunePlan) {
            break
        }
    }
}
if (-not $hasIntunePlan) {
    throw 'Intune license preflight failed: no enabled SKU with an active INTUNE_A* service plan was found in the tenant.'
}

# 2. Preflight check: MDM auto-enrollment and Windows multi-session device enrollment restrictions
$enrollmentConfigs = Invoke-GraphRequest -Method 'GET' -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations' -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
if ($null -ne $enrollmentConfigs -and $null -ne $enrollmentConfigs.PSObject.Properties['value']) {
    foreach ($cfg in $enrollmentConfigs.value) {
        if ($null -ne $cfg.PSObject.Properties['windowsRestriction'] -and $null -ne $cfg.windowsRestriction) {
            if ($cfg.windowsRestriction.platformBlocked -eq $true) {
                throw "MDM enrollment check failed: Windows device enrollment is blocked by configuration '$($cfg.displayName)' ($($cfg.id))."
            }
        }
    }
}

$settingsCatalogDir = Join-Path $resolvedProfilesDir 'settings-catalog'
$complianceDir = Join-Path $resolvedProfilesDir 'compliance'

$settingsCatalogFiles = @(Get-ChildItem -Path $settingsCatalogDir -Filter '*.json' -File | Sort-Object Name)
$complianceFiles = @(Get-ChildItem -Path $complianceDir -Filter '*.json' -File | Sort-Object Name)

if ($settingsCatalogFiles.Count -eq 0) {
    throw "No Settings Catalog profile JSON templates found in '$settingsCatalogDir'."
}
if ($complianceFiles.Count -eq 0) {
    throw "No compliance policy JSON templates found in '$complianceDir'."
}

$settingsCatalogPolicyIds = @()
$runManifestResources = @()
$assignmentFilterMap = [ordered]@{}
$useAssignmentFilters = $DeployAssignmentFilters.IsPresent -or $IncludeWin365.IsPresent

# 2b. Optional Platform Assignment Filters deployment (avd-multisession, avd-personal, win365-cloudpc, physical-desktop)
if ($useAssignmentFilters) {
    $filtersDir = Join-Path $resolvedProfilesDir 'filters'
    if (Test-Path -LiteralPath $filtersDir) {
        $filterFiles = @(Get-ChildItem -Path $filtersDir -Filter '*.json' -File | Sort-Object Name)
        foreach ($filterFile in $filterFiles) {
            $filterObj = Get-Content -LiteralPath $filterFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $stampedFilterName = Get-StampedName -RawName ([string]$filterObj.displayName) -StampPrefix $stampPrefix
            $filterPayload = [ordered]@{
                displayName = $stampedFilterName
                description = [string]$filterObj.description
                platform    = [string]$filterObj.platform
                rule        = [string]$filterObj.rule
            }
            $escapedFilterName = $stampedFilterName.Replace("'", "''")
            $filterQueryUri = "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters?`$filter=displayName eq '$escapedFilterName'"
            $existingFilterResp = Invoke-GraphRequest -Method 'GET' -Uri $filterQueryUri -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
            $matchedFilter = $null
            if ($null -ne $existingFilterResp -and $null -ne $existingFilterResp.PSObject.Properties['value']) {
                $matchedFilter = @($existingFilterResp.value | Where-Object { $_.displayName -eq $stampedFilterName } | Select-Object -First 1)
            }
            $filterCreated = $false
            $filterId = ''
            if ($null -ne $matchedFilter -and $matchedFilter.Count -gt 0 -and $null -ne $matchedFilter[0]) {
                $filterId = [string]$matchedFilter[0].id
                $patchFilterUri = "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters/$filterId"
                $null = Invoke-GraphRequest -Method 'PATCH' -Uri $patchFilterUri -Body $filterPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
                $filterCreated = $false
            } else {
                $postFilterUri = 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters'
                $createdFilter = Invoke-GraphRequest -Method 'POST' -Uri $postFilterUri -Body $filterPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
                $filterId = [string]$createdFilter.id
                $filterCreated = $true
            }
            $assignmentFilterMap[$filterFile.BaseName] = $filterId
            $runManifestResources += [ordered]@{
                resourceType = 'assignmentFilter'
                id           = $filterId
                displayName  = $stampedFilterName
                sourceFile   = $filterFile.Name
                created      = $filterCreated
                assignedTo   = 'tenant'
            }
        }
    }
}

# 3. Idempotent Settings Catalog profiles deployment & assignment
foreach ($profileFile in $settingsCatalogFiles) {
    $profileObj = Get-Content -LiteralPath $profileFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $stampedName = Get-StampedName -RawName ([string]$profileObj.name) -StampPrefix $stampPrefix
    $payload = ConvertTo-GraphConfigurationPolicyPayload -ProfileObject $profileObj -StampedName $stampedName

    $escapedName = $stampedName.Replace("'", "''")
    $filterUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=name eq '$escapedName'"
    $existingResp = Invoke-GraphRequest -Method 'GET' -Uri $filterUri -IsDryRun $isDryRun -CustomInvoker $GraphInvoker

    $matchedPolicy = $null
    if ($null -ne $existingResp -and $null -ne $existingResp.PSObject.Properties['value']) {
        $matchedPolicy = @($existingResp.value | Where-Object { $_.name -eq $stampedName } | Select-Object -First 1)
    }

    $wasCreated = $false
    $policyId = ''
    if ($null -ne $matchedPolicy -and $matchedPolicy.Count -gt 0 -and $null -ne $matchedPolicy[0]) {
        $policyId = [string]$matchedPolicy[0].id
        $patchUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId"
        $null = Invoke-GraphRequest -Method 'PATCH' -Uri $patchUri -Body $payload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $wasCreated = $false
    } else {
        $postUri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'
        $createdPolicy = Invoke-GraphRequest -Method 'POST' -Uri $postUri -Body $payload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $policyId = [string]$createdPolicy.id
        $wasCreated = $true
    }

    $targetSpec = [ordered]@{
        '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
        groupId       = $targetDeviceGroupId
    }
    if ($assignmentFilterMap.Contains('avd-multisession')) {
        $targetSpec['deviceAndAppManagementAssignmentFilterId'] = [string]$assignmentFilterMap['avd-multisession']
        $targetSpec['deviceAndAppManagementAssignmentFilterType'] = 'include'
    }
    $assignPayload = [ordered]@{
        assignments = @(
            [ordered]@{
                target = $targetSpec
            }
        )
    }
    $assignUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/assign"
    $null = Invoke-GraphRequest -Method 'POST' -Uri $assignUri -Body $assignPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker

    $settingsCatalogPolicyIds += $policyId
    $runManifestResources += [ordered]@{
        resourceType = 'configurationPolicy'
        id           = $policyId
        displayName  = $stampedName
        sourceFile   = $profileFile.Name
        created      = $wasCreated
        assignedTo   = $targetDeviceGroupId
    }
}

# 4. Idempotent Compliance Policy deployment & assignment
$compliancePolicyIds = @()
foreach ($compFile in $complianceFiles) {
    $compObj = Get-Content -LiteralPath $compFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $stampedDisplayName = Get-StampedName -RawName ([string]$compObj.displayName) -StampPrefix $stampPrefix

    $compPayload = [ordered]@{}
    foreach ($prop in $compObj.PSObject.Properties) {
        $compPayload[$prop.Name] = $prop.Value
    }
    $compPayload['displayName'] = $stampedDisplayName

    $escapedDisplayName = $stampedDisplayName.Replace("'", "''")
    $filterUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$filter=displayName eq '$escapedDisplayName'"
    $existingResp = Invoke-GraphRequest -Method 'GET' -Uri $filterUri -IsDryRun $isDryRun -CustomInvoker $GraphInvoker

    $matchedComp = $null
    if ($null -ne $existingResp -and $null -ne $existingResp.PSObject.Properties['value']) {
        $matchedComp = @($existingResp.value | Where-Object { $_.displayName -eq $stampedDisplayName } | Select-Object -First 1)
    }

    $wasCreated = $false
    $compPolicyId = ''
    if ($null -ne $matchedComp -and $matchedComp.Count -gt 0 -and $null -ne $matchedComp[0]) {
        $compPolicyId = [string]$matchedComp[0].id
        $patchUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$compPolicyId"
        $null = Invoke-GraphRequest -Method 'PATCH' -Uri $patchUri -Body $compPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $wasCreated = $false
    } else {
        $postUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies'
        $createdComp = Invoke-GraphRequest -Method 'POST' -Uri $postUri -Body $compPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $compPolicyId = [string]$createdComp.id
        $wasCreated = $true
    }

    $targetSpec = [ordered]@{
        '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
        groupId       = $targetDeviceGroupId
    }
    if ($assignmentFilterMap.Contains('avd-multisession')) {
        $targetSpec['deviceAndAppManagementAssignmentFilterId'] = [string]$assignmentFilterMap['avd-multisession']
        $targetSpec['deviceAndAppManagementAssignmentFilterType'] = 'include'
    }
    $assignPayload = [ordered]@{
        assignments = @(
            [ordered]@{
                target = $targetSpec
            }
        )
    }
    $assignUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$compPolicyId/assign"
    $null = Invoke-GraphRequest -Method 'POST' -Uri $assignUri -Body $assignPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker

    $compliancePolicyIds += $compPolicyId
    $runManifestResources += [ordered]@{
        resourceType = 'deviceCompliancePolicy'
        id           = $compPolicyId
        displayName  = $stampedDisplayName
        sourceFile   = $compFile.Name
        created      = $wasCreated
        assignedTo   = $targetDeviceGroupId
    }
}

# 4b. Optional Windows 365 Cloud PC Provisioning Policies, User Settings, and ANC Health Check (-IncludeWin365)
$win365ProvisioningPolicyIds = @()
$win365UserSettingsIds = @()
if ($IncludeWin365.IsPresent) {
    $win365UsersGroupId = if ($null -ne $entraManifest.groups.PSObject.Properties['win365UsersGroupId'] -and -not [string]::IsNullOrWhiteSpace([string]$entraManifest.groups.win365UsersGroupId)) {
        [string]$entraManifest.groups.win365UsersGroupId
    } else {
        $avdUsersGroupId
    }

    $ancResp = Invoke-GraphRequest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/onPremisesConnections' -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
    if ($null -ne $ancResp -and $null -ne $ancResp.PSObject.Properties['value']) {
        foreach ($anc in $ancResp.value) {
            if ($null -ne $anc.PSObject.Properties['healthCheckStatus'] -and $anc.healthCheckStatus -eq 'failed') {
                throw "Windows 365 Azure Network Connection (ANC) '$($anc.displayName)' ($($anc.id)) has healthCheckStatus='failed'."
            }
        }
    }

    $win365Dir = Join-Path $resolvedProfilesDir 'win365'
    $provFile = Join-Path $win365Dir 'provisioning-policy.json'
    if (Test-Path -LiteralPath $provFile) {
        $provObj = Get-Content -LiteralPath $provFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $stampedProvName = Get-StampedName -RawName ([string]$provObj.displayName) -StampPrefix $stampPrefix
        $provPayload = [ordered]@{}
        foreach ($prop in $provObj.PSObject.Properties) {
            $provPayload[$prop.Name] = $prop.Value
        }
        $provPayload['displayName'] = $stampedProvName

        $existingProvResp = Invoke-GraphRequest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/provisioningPolicies' -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $matchedProv = $null
        if ($null -ne $existingProvResp -and $null -ne $existingProvResp.PSObject.Properties['value']) {
            $matchedProv = @($existingProvResp.value | Where-Object { $_.displayName -eq $stampedProvName } | Select-Object -First 1)
        }
        $provCreated = $false
        $provId = ''
        if ($null -ne $matchedProv -and $matchedProv.Count -gt 0 -and $null -ne $matchedProv[0]) {
            $provId = [string]$matchedProv[0].id
            $null = Invoke-GraphRequest -Method 'PATCH' -Uri "https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/provisioningPolicies/$provId" -Body $provPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
            $provCreated = $false
        } else {
            $createdProv = Invoke-GraphRequest -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/provisioningPolicies' -Body $provPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
            $provId = [string]$createdProv.id
            $provCreated = $true
        }
        $provAssignPayload = [ordered]@{
            assignments = @(
                [ordered]@{
                    target = [ordered]@{
                        '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'
                        groupId       = $win365UsersGroupId
                    }
                }
            )
        }
        $null = Invoke-GraphRequest -Method 'POST' -Uri "https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/provisioningPolicies/$provId/assign" -Body $provAssignPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $win365ProvisioningPolicyIds += $provId
        $runManifestResources += [ordered]@{
            resourceType = 'cloudPcProvisioningPolicy'
            id           = $provId
            displayName  = $stampedProvName
            sourceFile   = 'provisioning-policy.json'
            created      = $provCreated
            assignedTo   = $win365UsersGroupId
        }
    }

    $userSettingFile = Join-Path $win365Dir 'user-setting.json'
    if (Test-Path -LiteralPath $userSettingFile) {
        $usObj = Get-Content -LiteralPath $userSettingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $stampedUsName = Get-StampedName -RawName ([string]$usObj.displayName) -StampPrefix $stampPrefix
        $usPayload = [ordered]@{}
        foreach ($prop in $usObj.PSObject.Properties) {
            $usPayload[$prop.Name] = $prop.Value
        }
        $usPayload['displayName'] = $stampedUsName

        $existingUsResp = Invoke-GraphRequest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/userSettings' -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $matchedUs = $null
        if ($null -ne $existingUsResp -and $null -ne $existingUsResp.PSObject.Properties['value']) {
            $matchedUs = @($existingUsResp.value | Where-Object { $_.displayName -eq $stampedUsName } | Select-Object -First 1)
        }
        $usCreated = $false
        $usId = ''
        if ($null -ne $matchedUs -and $matchedUs.Count -gt 0 -and $null -ne $matchedUs[0]) {
            $usId = [string]$matchedUs[0].id
            $null = Invoke-GraphRequest -Method 'PATCH' -Uri "https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/userSettings/$usId" -Body $usPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
            $usCreated = $false
        } else {
            $createdUs = Invoke-GraphRequest -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/userSettings' -Body $usPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
            $usId = [string]$createdUs.id
            $usCreated = $true
        }
        $usAssignPayload = [ordered]@{
            assignments = @(
                [ordered]@{
                    target = [ordered]@{
                        '@odata.type' = '#microsoft.graph.cloudPcManagementGroupAssignmentTarget'
                        groupId       = $win365UsersGroupId
                    }
                }
            )
        }
        $null = Invoke-GraphRequest -Method 'POST' -Uri "https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/userSettings/$usId/assign" -Body $usAssignPayload -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $win365UserSettingsIds += $usId
        $runManifestResources += [ordered]@{
            resourceType = 'cloudPcUserSetting'
            id           = $usId
            displayName  = $stampedUsName
            sourceFile   = 'user-setting.json'
            created      = $usCreated
            assignedTo   = $win365UsersGroupId
        }
    }
}

# 5. Write intune-run-manifest.json and intune-manifest.json
$runManifest = [ordered]@{
    schema              = 'avd-ops-intune-run-manifest/v1'
    stampPrefix         = $stampPrefix
    environment         = $environment
    prefix              = $resolvedPrefix
    targetDeviceGroupId = $targetDeviceGroupId
    avdUsersGroupId     = $avdUsersGroupId
    generatedAtUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    dryRun              = [bool]$isDryRun
    resources           = $runManifestResources
}

$runJson = $runManifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($RunManifestPath, $runJson + "`n", [System.Text.UTF8Encoding]::new($false))

$handoffManifest = [ordered]@{
    schema                  = 'avd-ops-intune-manifest/v1'
    environment             = $environment
    targetDeviceGroupId     = $targetDeviceGroupId
    settingsCatalogProfiles = @($settingsCatalogPolicyIds)
    compliancePolicyId      = [string]$compliancePolicyIds[0]
}
if ($assignmentFilterMap.Count -gt 0) {
    $handoffManifest['assignmentFilters'] = $assignmentFilterMap
}
if ($IncludeWin365.IsPresent) {
    $handoffManifest['win365'] = [ordered]@{
        provisioningPolicyIds = @($win365ProvisioningPolicyIds)
        userSettingsIds       = @($win365UserSettingsIds)
    }
}

$handoffJson = $handoffManifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutputPath, $handoffJson + "`n", [System.Text.UTF8Encoding]::new($false))

$pythonExe = Resolve-PythonExecutable
$validateScript = Join-Path $PSScriptRoot 'validate.py'
& $pythonExe $validateScript --manifest $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "Contract validation failed for '$OutputPath'."
}
