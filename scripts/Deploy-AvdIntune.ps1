# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][string]$EntraManifestPath = './entra-manifest.json',
    [Parameter()][string]$OutputPath = './intune-manifest.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ShouldProcess('Microsoft Intune', 'Deploy AVD Settings Catalog and compliance profiles')) {
    & bash ./scripts/deploy-intune.sh $EntraManifestPath $OutputPath
}
