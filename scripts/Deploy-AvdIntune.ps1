# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][string]$EntraManifestPath = './entra-manifest.json',
    [Parameter()][string]$OutputPath = './intune-manifest.json',
    [Parameter()][string]$RunManifestPath = './intune-run-manifest.json',
    [Parameter()][string]$ProfilesDirectory = '',
    [Parameter()][string]$Prefix = '',
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

    $assignPayload = [ordered]@{
        assignments = @(
            [ordered]@{
                target = [ordered]@{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    groupId       = $targetDeviceGroupId
                }
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

    $assignPayload = [ordered]@{
        assignments = @(
            [ordered]@{
                target = [ordered]@{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    groupId       = $targetDeviceGroupId
                }
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

$handoffJson = $handoffManifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutputPath, $handoffJson + "`n", [System.Text.UTF8Encoding]::new($false))

$pythonExe = Resolve-PythonExecutable
$validateScript = Join-Path $PSScriptRoot 'validate.py'
& $pythonExe $validateScript --manifest $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "Contract validation failed for '$OutputPath'."
}
