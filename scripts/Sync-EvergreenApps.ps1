# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding()]
param(
    [Parameter()][string]$AppManifestPath = (Join-Path $PSScriptRoot '../profiles/apps/core-host-apps.json'),
    [Parameter()][string]$OutputPath = './evergreen-apps-resolved.json',
    [Parameter()][switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AppManifestPath)) {
    throw "App manifest not found at '$AppManifestPath'."
}

$manifest = Get-Content -LiteralPath $AppManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $manifest.apps -or $manifest.apps.Count -eq 0) {
    throw "App manifest '$AppManifestPath' contains no apps."
}

$useEvergreen = $false
if (-not $DryRun.IsPresent) {
    if ($null -ne (Get-Module -ListAvailable -Name 'Evergreen')) {
        Import-Module Evergreen -ErrorAction Stop
        $useEvergreen = $true
    } else {
        throw "PowerShell module 'Evergreen' (EUCPilots/evergreen-module) is not installed. Install with: Install-Module Evergreen -Scope CurrentUser (or pass -DryRun)."
    }
}

$resolved = @()
foreach ($app in $manifest.apps) {
    if ($app.installContext -ne 'system' -or $app.intent -ne 'required' -or $app.targetType -ne 'deviceGroup') {
        throw "App '$($app.id)' violates avd-assess methods/intune.md step 8 (must be system context, required, deviceGroup)."
    }

    $version = 'dry-run'
    $uri = "https://evergreen.local/dry-run/$($app.evergreenApp)"
    if ($useEvergreen) {
        if ($app.evergreenApp -eq 'VcRedist') {
            if ($null -eq (Get-Module -ListAvailable -Name 'VcRedist')) {
                throw "PowerShell module 'VcRedist' (EUCPilots/vcredist) is not installed. Install with: Install-Module VcRedist -Scope CurrentUser."
            }
            Import-Module VcRedist -ErrorAction Stop
            $vcList = @(Get-VcList -Release 2022 -Architecture x64 | Select-Object -First 1)
            if ($vcList.Count -gt 0) {
                $version = [string]$vcList[0].Version
                $uri = [string]$vcList[0].URI
            }
        } else {
            $egItems = @(Get-EvergreenApp -Name $app.evergreenApp)
            if ($egItems.Count -gt 0) {
                $version = [string]$egItems[0].Version
                $uri = [string]$egItems[0].URI
            }
        }
    }

    $resolved += [ordered]@{
        id             = [string]$app.id
        displayName    = [string]$app.displayName
        evergreenApp   = [string]$app.evergreenApp
        version        = $version
        uri            = $uri
        installContext = [string]$app.installContext
        intent         = [string]$app.intent
        targetType     = [string]$app.targetType
    }
}

$payload = [ordered]@{
    schema         = 'avd-ops-evergreen-apps/v1'
    upstream       = $manifest.upstream
    targetFilters  = @($manifest.targetFilters)
    dryRun         = [bool]$DryRun.IsPresent
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    apps           = $resolved
}

$json = $payload | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutputPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output "Resolved $($resolved.Count) core host apps to '$OutputPath'."
