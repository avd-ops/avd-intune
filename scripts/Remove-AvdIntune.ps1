# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()][string]$RunManifestPath = './intune-run-manifest.json',
    [Parameter()][ValidateSet('commercial', 'usgov')][string]$Cloud = 'commercial',
    [Parameter()][ValidateSet('standard', 'itar-cui')][string]$ComplianceProfile = '',
    [Parameter()][switch]$DiscardLastCopy,
    [Parameter()][switch]$DryRun,
    [Parameter()][scriptblock]$GraphInvoker
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AvdCloudEnvironment {
    param(
        [Parameter(Mandatory)][ValidateSet('commercial', 'usgov')][string]$CloudName
    )
    $contractPath = Join-Path $PSScriptRoot '../contracts/cloud-environments.json'
    if (-not (Test-Path -LiteralPath $contractPath)) {
        throw "Cloud environments contract (C26) not found at '$contractPath'."
    }
    $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $contract.PSObject.Properties['clouds'] -and $null -ne $contract.clouds.PSObject.Properties[$CloudName]) {
        return $contract.clouds.$CloudName
    }
    $matched = @($contract.environments | Where-Object { $_.id -eq $CloudName } | Select-Object -First 1)
    if ($matched.Count -eq 0 -or $null -eq $matched[0]) {
        throw "Cloud environment '$CloudName' not found in '$contractPath'."
    }
    return $matched[0]
}

function Assert-AvdCloudContextMatch {
    param(
        [Parameter(Mandatory)][object]$CloudEnv,
        [Parameter(Mandatory)][string]$TargetCloud
    )
    $getAzCtxCmd = Get-Command 'Get-AzContext' -ErrorAction SilentlyContinue
    if ($null -ne $getAzCtxCmd) {
        $azCtx = & $getAzCtxCmd -ErrorAction SilentlyContinue
        if ($null -ne $azCtx -and $null -ne $azCtx.PSObject.Properties['Environment'] -and $null -ne $azCtx.Environment) {
            $activeAzEnv = [string]$azCtx.Environment.Name
            if (-not [string]::IsNullOrWhiteSpace($activeAzEnv) -and $activeAzEnv -ne [string]$CloudEnv.psEnvironmentName) {
                throw "Cloud boundary mismatch: active Az PowerShell environment is '$activeAzEnv', but target cloud '$TargetCloud' requires '$($CloudEnv.psEnvironmentName)'."
            }
        }
    }
    $getMgCtxCmd = Get-Command 'Get-MgContext' -ErrorAction SilentlyContinue
    if ($null -ne $getMgCtxCmd) {
        $mgCtx = & $getMgCtxCmd -ErrorAction SilentlyContinue
        if ($null -ne $mgCtx -and $null -ne $mgCtx.PSObject.Properties['Environment']) {
            $activeMgEnv = [string]$mgCtx.Environment
            if (-not [string]::IsNullOrWhiteSpace($activeMgEnv) -and $activeMgEnv -ne [string]$CloudEnv.entraEnvironment) {
                throw "Cloud boundary mismatch: active MgGraph environment is '$activeMgEnv', but target cloud '$TargetCloud' requires '$($CloudEnv.entraEnvironment)' (Connect-MgGraph -Environment $($CloudEnv.entraEnvironment))."
            }
        }
    }
}

function Invoke-GraphDeleteRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][bool]$IsDryRun = $false,
        [Parameter()][scriptblock]$CustomInvoker = $null,
        [Parameter()][string]$GraphResource = ''
    )
    if ($null -ne $CustomInvoker) {
        return (& $CustomInvoker 'DELETE' $Uri $null)
    }
    if ($IsDryRun) {
        return [pscustomobject]@{ status = 'deleted' }
    }
    $azArgs = @('rest', '--method', 'DELETE', '--uri', $Uri)
    if (-not [string]::IsNullOrWhiteSpace($GraphResource)) {
        $azArgs += @('--resource', $GraphResource)
    }
    $rawOut = & az @azArgs
    if ($LASTEXITCODE -ne 0) {
        throw "az rest failed (DELETE $Uri) with exit code $LASTEXITCODE"
    }
    return $rawOut
}

if (-not $DiscardLastCopy.IsPresent) {
    throw 'Refusing to delete Intune policies or run-manifest state without -DiscardLastCopy. Verify a backup copy exists or pass -DiscardLastCopy explicitly.'
}

if (-not (Test-Path -LiteralPath $RunManifestPath)) {
    throw "Intune run manifest not found at '$RunManifestPath'."
}

$isDryRun = $DryRun.IsPresent -or ($env:AVD_OPS_DRY_RUN -eq '1')
$runManifest = Get-Content -LiteralPath $RunManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$manifestCloud = if ($null -ne $runManifest.PSObject.Properties['cloud'] -and -not [string]::IsNullOrWhiteSpace([string]$runManifest.cloud)) {
    ([string]$runManifest.cloud).Trim().ToLowerInvariant()
} else {
    ''
}
$resolvedCloud = if ($PSBoundParameters.ContainsKey('Cloud')) {
    $Cloud.Trim().ToLowerInvariant()
} elseif (-not [string]::IsNullOrWhiteSpace($manifestCloud)) {
    $manifestCloud
} else {
    $Cloud.Trim().ToLowerInvariant()
}
if (-not [string]::IsNullOrWhiteSpace($manifestCloud) -and $manifestCloud -ne $resolvedCloud) {
    throw "Cloud boundary mismatch: intune-run-manifest.json declares cloud='$manifestCloud', but Remove-AvdIntune.ps1 was invoked with -Cloud '$resolvedCloud'."
}

$cloudEnv = Resolve-AvdCloudEnvironment -CloudName $resolvedCloud
$graphBaseUri = ([string]$cloudEnv.graphEndpoint).TrimEnd('/')
Assert-AvdCloudContextMatch -CloudEnv $cloudEnv -TargetCloud $resolvedCloud

$resolvedComplianceProfile = if ($PSBoundParameters.ContainsKey('ComplianceProfile') -and -not [string]::IsNullOrWhiteSpace($ComplianceProfile)) {
    $ComplianceProfile.Trim().ToLowerInvariant()
} elseif ($null -ne $runManifest.PSObject.Properties['complianceProfile'] -and -not [string]::IsNullOrWhiteSpace([string]$runManifest.complianceProfile)) {
    ([string]$runManifest.complianceProfile).Trim().ToLowerInvariant()
} elseif ($resolvedCloud -eq 'usgov') {
    'itar-cui'
} else {
    'standard'
}

$stampPrefix = if ($null -ne $runManifest.PSObject.Properties['stampPrefix'] -and -not [string]::IsNullOrWhiteSpace([string]$runManifest.stampPrefix)) {
    [string]$runManifest.stampPrefix
} else {
    $prefix = [string]$runManifest.prefix
    $envName = [string]$runManifest.environment
    "[avd-ops-$prefix-$envName]"
}

$removedIds = @()
$skippedIds = @()

foreach ($res in $runManifest.resources) {
    $resId = [string]$res.id
    $displayName = [string]$res.displayName
    $resType = [string]$res.resourceType
    $wasCreated = ($res.created -eq $true)

    if (-not $wasCreated) {
        Write-Verbose "Skipping '$displayName' ($resId): created=false (pre-existing resource)."
        $skippedIds += $resId
        continue
    }

    if (-not $displayName.StartsWith($stampPrefix, [System.StringComparison]::Ordinal)) {
        Write-Verbose "Skipping '$displayName' ($resId): does not match stamp prefix '$stampPrefix'."
        $skippedIds += $resId
        continue
    }

    $deleteUri = switch ($resType) {
        'configurationPolicy' { "$graphBaseUri/beta/deviceManagement/configurationPolicies/$resId" }
        'deviceCompliancePolicy' { "$graphBaseUri/beta/deviceManagement/deviceCompliancePolicies/$resId" }
        'assignmentFilter' { "$graphBaseUri/beta/deviceManagement/assignmentFilters/$resId" }
        'cloudPcProvisioningPolicy' { "$graphBaseUri/v1.0/deviceManagement/virtualEndpoint/provisioningPolicies/$resId" }
        'cloudPcUserSetting' { "$graphBaseUri/v1.0/deviceManagement/virtualEndpoint/userSettings/$resId" }
        default { throw "Unsupported resourceType '$resType' in run manifest." }
    }

    if ($PSCmdlet.ShouldProcess("$displayName ($resId)", "DELETE $deleteUri")) {
        $null = Invoke-GraphDeleteRequest -Uri $deleteUri -IsDryRun $isDryRun -CustomInvoker $GraphInvoker -GraphResource $graphBaseUri
        $removedIds += $resId
    }
}

[pscustomobject]@{
    stampPrefix       = $stampPrefix
    cloud             = $resolvedCloud
    complianceProfile = $resolvedComplianceProfile
    removedIds        = $removedIds
    skippedIds        = $skippedIds
}
