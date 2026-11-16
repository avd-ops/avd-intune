# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding()]
param(
    [Parameter()][string]$AppManifestPath = (Join-Path $PSScriptRoot '../profiles/apps/core-host-apps.json'),
    [Parameter()][string]$OutputPath = './evergreen-apps-resolved.json',
    [Parameter()][switch]$DryRun,
    [Parameter()][scriptblock]$AppResolver
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-EvergreenFilter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter()][string]$FilterExpression = ''
    )
    if ([string]::IsNullOrWhiteSpace($FilterExpression)) {
        return $true
    }
    $clauses = $FilterExpression -split '\s+-and\s+'
    foreach ($clause in $clauses) {
        $trimmed = $clause.Trim()
        if ($trimmed -notmatch "^([A-Za-z0-9_]+)\s+-eq\s+'([^']*)'$") {
            throw "Unsupported evergreenFilter clause '$trimmed'. Expected '<Property> -eq ''<Value>'''."
        }
        $propName = $Matches[1]
        $expected = $Matches[2]
        $prop = $Item.PSObject.Properties[$propName]
        if ($null -eq $prop -or [string]$prop.Value -ne $expected) {
            return $false
        }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $AppManifestPath)) {
    throw "App manifest not found at '$AppManifestPath'."
}

$manifest = Get-Content -LiteralPath $AppManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $manifest.apps -or $manifest.apps.Count -eq 0) {
    throw "App manifest '$AppManifestPath' contains no apps."
}

$useLiveModules = $false
if (-not $DryRun.IsPresent -and $null -eq $AppResolver) {
    if ($null -ne (Get-Module -ListAvailable -Name 'Evergreen')) {
        Import-Module Evergreen -ErrorAction Stop
        if ($null -ne (Get-Command -Name 'Update-Evergreen' -ErrorAction SilentlyContinue)) {
            Update-Evergreen | Out-Null
        }
        $useLiveModules = $true
    } else {
        throw "PowerShell module 'Evergreen' (EUCPilots/evergreen-module) is not installed. Install with: Install-Module Evergreen -Scope CurrentUser (or pass -DryRun)."
    }
}

$resolved = @()
foreach ($app in $manifest.apps) {
    if ($app.installContext -ne 'system' -or $app.intent -ne 'required' -or $app.targetType -ne 'deviceGroup') {
        throw "App '$($app.id)' violates avd-assess methods/intune.md step 8 (must be system context, required, deviceGroup)."
    }

    $filterExpr = if ($null -ne $app.PSObject.Properties['evergreenFilter']) { [string]$app.evergreenFilter } else { '' }
    $version = 'dry-run'
    $uri = "https://evergreen.local/dry-run/$($app.evergreenApp)"
    $sha256 = ''
    $releaseDate = ''

    if ($null -ne $AppResolver) {
        $candidates = @(& $AppResolver $app)
        $matched = @($candidates | Where-Object { Test-EvergreenFilter -Item $_ -FilterExpression $filterExpr })
        if ($matched.Count -eq 0) {
            throw "No items matched evergreenFilter '$filterExpr' for app '$($app.id)'."
        }
        $selected = $matched[0]
        $version = [string]$selected.Version
        $uri = [string]$selected.URI
        if ($null -ne $selected.PSObject.Properties['Sha256']) { $sha256 = [string]$selected.Sha256 }
        if ($null -ne $selected.PSObject.Properties['Date']) { $releaseDate = [string]$selected.Date }
    } elseif ($useLiveModules) {
        if ($app.evergreenApp -eq 'VcRedist') {
            if ($null -eq (Get-Module -ListAvailable -Name 'VcRedist')) {
                throw "PowerShell module 'VcRedist' (EUCPilots/vcredist) is not installed. Install with: Install-Module VcRedist -Scope CurrentUser."
            }
            Import-Module VcRedist -ErrorAction Stop
            $vcList = @(Get-VcList -Release 2022 -Architecture x64)
            $matched = @($vcList | Where-Object { Test-EvergreenFilter -Item $_ -FilterExpression $filterExpr })
            if ($matched.Count -eq 0) {
                throw "No VcRedist items matched evergreenFilter '$filterExpr' for app '$($app.id)'."
            }
            $selected = $matched[0]
            $version = [string]$selected.Version
            $uri = [string]$selected.URI
        } else {
            $egItems = @(Get-EvergreenApp -Name $app.evergreenApp)
            $matched = @($egItems | Where-Object { Test-EvergreenFilter -Item $_ -FilterExpression $filterExpr })
            if ($matched.Count -eq 0) {
                throw "No Evergreen items matched evergreenFilter '$filterExpr' for app '$($app.id)'."
            }
            $selected = $matched[0]
            $version = [string]$selected.Version
            $uri = [string]$selected.URI
            if ($null -ne $selected.PSObject.Properties['Sha256']) { $sha256 = [string]$selected.Sha256 }
            if ($null -ne $selected.PSObject.Properties['Date']) { $releaseDate = [string]$selected.Date }
        }
    }

    $entry = [ordered]@{
        id             = [string]$app.id
        displayName    = [string]$app.displayName
        evergreenApp   = [string]$app.evergreenApp
        version        = $version
        uri            = $uri
        installContext = [string]$app.installContext
        intent         = [string]$app.intent
        targetType     = [string]$app.targetType
    }
    if (-not [string]::IsNullOrWhiteSpace($sha256)) { $entry['sha256'] = $sha256 }
    if (-not [string]::IsNullOrWhiteSpace($releaseDate)) { $entry['date'] = $releaseDate }
    $resolved += $entry
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
