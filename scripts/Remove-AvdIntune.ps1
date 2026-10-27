# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()][string]$RunManifestPath = './intune-run-manifest.json',
    [Parameter()][switch]$DiscardLastCopy,
    [Parameter()][switch]$DryRun,
    [Parameter()][scriptblock]$GraphInvoker
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GraphDeleteRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][bool]$IsDryRun = $false,
        [Parameter()][scriptblock]$CustomInvoker = $null
    )
    if ($null -ne $CustomInvoker) {
        return (& $CustomInvoker 'DELETE' $Uri $null)
    }
    if ($IsDryRun) {
        return [pscustomobject]@{ status = 'deleted' }
    }
    $rawOut = & az rest --method DELETE --uri $Uri
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
        'configurationPolicy' { "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$resId" }
        'deviceCompliancePolicy' { "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$resId" }
        default { throw "Unsupported resourceType '$resType' in run manifest." }
    }

    if ($PSCmdlet.ShouldProcess("$displayName ($resId)", "DELETE $deleteUri")) {
        $null = Invoke-GraphDeleteRequest -Uri $deleteUri -IsDryRun $isDryRun -CustomInvoker $GraphInvoker
        $removedIds += $resId
    }
}

[pscustomobject]@{
    stampPrefix = $stampPrefix
    removedIds  = $removedIds
    skippedIds  = $skippedIds
}
