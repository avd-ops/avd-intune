# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command 'Describe' -ErrorAction SilentlyContinue)) {
    function global:Describe {
        param([string]$Name, [scriptblock]$Fixture)
        Write-Host "Describe: $Name"
        & $Fixture
    }
    function global:BeforeAll {
        param([scriptblock]$Action)
        & $Action
    }
    function global:It {
        param([string]$Name, [scriptblock]$Test)
        $script:TestDrive = Join-Path ([System.IO.Path]::GetTempPath()) ('pester-shim-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:TestDrive -Force
        try {
            & $Test
            Write-Host "  [+] $Name"
        } finally {
            if (Test-Path -LiteralPath $script:TestDrive) {
                Remove-Item -LiteralPath $script:TestDrive -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    function global:Should {
        param(
            [Parameter(ValueFromPipeline)][object]$ActualValue,
            [switch]$BeTrue,
            [switch]$BeFalse,
            [object]$Be = $null,
            [switch]$BeGreaterOrEqual,
            [switch]$BeGreaterThan,
            [string]$Match = '',
            [string]$Throw = '',
            [switch]$Not,
            [string]$Because = ''
        )
        process {
            if ($PSBoundParameters.ContainsKey('Throw')) {
                $threw = $false
                $msg = ''
                try {
                    & $ActualValue
                } catch {
                    $threw = $true
                    $msg = $_.Exception.Message
                }
                if (-not $threw) {
                    throw "Expected scriptblock to throw '$Throw', but it did not throw."
                }
                if (-not [string]::IsNullOrEmpty($Throw) -and $msg -notlike $Throw) {
                    throw "Expected exception message matching '$Throw', got '$msg'."
                }
                return
            }
            if ($BeTrue) {
                if ($ActualValue -ne $true) { throw "Expected True, got '$ActualValue'. $Because" }
                return
            }
            if ($BeFalse) {
                if ($ActualValue -ne $false) { throw "Expected False, got '$ActualValue'. $Because" }
                return
            }
            if ($PSBoundParameters.ContainsKey('Be')) {
                if ($Not) {
                    if ($ActualValue -eq $Be) { throw "Expected not '$Be', got '$ActualValue'. $Because" }
                } else {
                    if ($ActualValue -ne $Be) { throw "Expected '$Be', got '$ActualValue'. $Because" }
                }
                return
            }
            if ($PSBoundParameters.ContainsKey('Match')) {
                $matched = ([string]$ActualValue -match $Match)
                if ($Not -and $matched) {
                    throw "Expected '$ActualValue' not to match '$Match'. $Because"
                }
                if (-not $Not -and -not $matched) {
                    throw "Expected '$ActualValue' to match '$Match'. $Because"
                }
            }
        }
    }
}

Describe 'US Gov / GCC High (C26) Static AST and Contract Guards' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:DeployScript = Join-Path $script:RepoRoot 'scripts/Deploy-AvdIntune.ps1'
        $script:RemoveScript = Join-Path $script:RepoRoot 'scripts/Remove-AvdIntune.ps1'
        $script:C26Path = Join-Path $script:RepoRoot 'contracts/cloud-environments.json'
        $script:LockdownProfilePath = Join-Path $script:RepoRoot 'profiles/settings-catalog/itar-cui-session-lockdown.json'

        $script:SampleEntraUsGov = [ordered]@{
            schema             = 'avd-ops-entra-manifest/v1'
            environment        = 'prod'
            cloud              = 'usgov'
            complianceProfile  = 'itar-cui'
            prefix             = 'contoso'
            groups             = [ordered]@{
                avdUsersGroupId            = '00000000-0000-0000-0000-000000000010'
                avdAdminsGroupId           = '00000000-0000-0000-0000-000000000011'
                sessionHostsDynamicGroupId = '00000000-0000-0000-0000-000000000012'
                breakGlassExcludeGroupId   = '00000000-0000-0000-0000-000000000013'
            }
            conditionalAccess  = @()
            entraKerberosReady = $true
        }
    }

    It 'pins contracts/cloud-environments.json (C26) with commercial and usgov Graph endpoints' {
        (Test-Path -LiteralPath $script:C26Path) | Should -BeTrue
        $c26 = Get-Content -LiteralPath $script:C26Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $c26.schema | Should -Be 'avd-cloud-environments/v1'
        $c26.clouds.commercial.graphEndpoint | Should -Be 'https://graph.microsoft.com'
        $c26.clouds.usgov.graphEndpoint | Should -Be 'https://graph.microsoft.us'
        $c26.clouds.usgov.entraEnvironment | Should -Be 'USGov'
        $c26.clouds.usgov.capabilities.win365MicrosoftHostedNetwork | Should -BeFalse
        $c26.clouds.usgov.capabilities.win365AzureNetworkConnection | Should -BeTrue
        $c26.clouds.usgov.capabilities.win365Frontline | Should -BeFalse
    }

    It 'has zero hardcoded commercial Graph or ARM endpoints in PowerShell scripts' {
        $psFiles = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' -File -Recurse)
        ($psFiles.Count -ge 2) | Should -BeTrue

        $disallowed = @(
            'management.azure.com',
            'graph.microsoft.com',
            'login.microsoftonline.com',
            'api.bap.microsoft.com',
            '.windows.net'
        )

        foreach ($file in $psFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $stringLiterals = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true)

            foreach ($lit in $stringLiterals) {
                foreach ($pattern in $disallowed) {
                    $lit.Extent.Text | Should -Not -Match ([regex]::Escape($pattern)) -Because "$($file.Name) must resolve cloud endpoints from C26"
                }
            }
        }
    }

    It 'defines ITAR-CUI-SessionLockdown Settings Catalog profile with FIPS 140, TLS 1.2+, disabled redirections, and screen capture protection / watermarking' {
        (Test-Path -LiteralPath $script:LockdownProfilePath) | Should -BeTrue
        $prof = Get-Content -LiteralPath $script:LockdownProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $prof.name | Should -Be '[avd-ops] ITAR-CUI-SessionLockdown'
        $prof.complianceProfile | Should -Be 'itar-cui'
        $ids = @($prof.settings | ForEach-Object { [string]$_.settingId })
        ($ids -join ' ') | Should -Match 'fips'
        ($ids -join ' ') | Should -Match 'tls'
        ($ids -join ' ') | Should -Match 'clipboard'
        ($ids -join ' ') | Should -Match 'printer'
        ($ids -join ' ') | Should -Match 'drive'
        ($ids -join ' ') | Should -Match 'plugandplay'
        ($ids -join ' ') | Should -Match 'usb'
        ($ids -join ' ') | Should -Match 'screencaptureprotection'
        ($ids -join ' ') | Should -Match 'watermarking'
    }

    It 'routes all Graph calls to https://graph.microsoft.us and deploys ITAR-CUI-SessionLockdown when -Cloud usgov' {
        $entraFile = Join-Path $TestDrive 'entra-usgov.json'
        $outFile = Join-Path $TestDrive 'intune-usgov.json'
        $runFile = Join-Path $TestDrive 'intune-run-usgov.json'
        ($script:SampleEntraUsGov | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $entraFile -Encoding UTF8

        $recordedUris = [System.Collections.Generic.List[string]]::new()
        $invoker = {
            param($Method, $Uri, $Body)
            $recordedUris.Add($Uri)
            if ($Method -eq 'GET' -and $Uri -like '*/subscribedSkus*') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        skuPartNumber    = 'SPE_E5_GOV'
                        capabilityStatus = 'Enabled'
                        servicePlans     = @([pscustomobject]@{
                            servicePlanName    = 'INTUNE_A'
                            provisioningStatus = 'Success'
                        })
                    })
                }
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }
            if ($Method -eq 'POST' -and $Uri -notlike '*/assign') {
                return [pscustomobject]@{ id = [guid]::NewGuid().ToString() }
            }
            return [pscustomobject]@{ status = 'ok' }
        }.GetNewClosure()

        & $script:DeployScript `
            -EntraManifestPath $entraFile `
            -OutputPath $outFile `
            -RunManifestPath $runFile `
            -Cloud 'usgov' `
            -GraphInvoker $invoker

        ($recordedUris.Count -gt 0) | Should -BeTrue
        foreach ($u in $recordedUris) {
            $u | Should -Match '^https://graph\.microsoft\.us/'
            $u | Should -Not -Match 'graph\.microsoft\.com'
        }

        $manifest = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.cloud | Should -Be 'usgov'
        $manifest.complianceProfile | Should -Be 'itar-cui'
        $manifest.settingsCatalogProfiles.Count | Should -Be 4

        $runManifest = Get-Content -LiteralPath $runFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $runManifest.cloud | Should -Be 'usgov'
        $runManifest.complianceProfile | Should -Be 'itar-cui'
        $lockdownEntry = @($runManifest.resources | Where-Object { $_.sourceFile -eq 'itar-cui-session-lockdown.json' })
        $lockdownEntry.Count | Should -Be 1
        $lockdownEntry[0].displayName | Should -Be '[avd-ops-contoso-prod] ITAR-CUI-SessionLockdown'
    }

    It 'fails closed before any Graph request when entra-manifest.json cloud mismatches -Cloud' {
        $entraFile = Join-Path $TestDrive 'entra-mismatch.json'
        ($script:SampleEntraUsGov | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $entraFile -Encoding UTF8

        $called = $false
        $invoker = {
            param($Method, $Uri, $Body)
            $script:called = $true
            return [pscustomobject]@{}
        }

        {
            & $script:DeployScript `
                -EntraManifestPath $entraFile `
                -OutputPath (Join-Path $TestDrive 'mismatch-out.json') `
                -RunManifestPath (Join-Path $TestDrive 'mismatch-run.json') `
                -Cloud 'commercial' `
                -GraphInvoker $invoker
        } | Should -Throw '*Cloud boundary mismatch*'
        $called | Should -BeFalse
    }

    It 'fails closed when active Get-MgContext environment mismatches target cloud' {
        $entraFile = Join-Path $TestDrive 'entra-mgmismatch.json'
        ($script:SampleEntraUsGov | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $entraFile -Encoding UTF8

        function global:Get-MgContext {
            return [pscustomobject]@{ Environment = 'Global' }
        }
        try {
            {
                & $script:DeployScript `
                    -EntraManifestPath $entraFile `
                    -OutputPath (Join-Path $TestDrive 'mg-out.json') `
                    -RunManifestPath (Join-Path $TestDrive 'mg-run.json') `
                    -Cloud 'usgov' `
                    -DryRun
            } | Should -Throw '*Cloud boundary mismatch*MgGraph*'
        } finally {
            Remove-Item -Path 'Function:\Get-MgContext' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'enforces Windows 365 Government ANC requirement and blocks MHN and Frontline in usgov' {
        $entraFile = Join-Path $TestDrive 'entra-w365-gov.json'
        ($script:SampleEntraUsGov | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $entraFile -Encoding UTF8

        {
            & $script:DeployScript `
                -EntraManifestPath $entraFile `
                -OutputPath (Join-Path $TestDrive 'w365-noanc.json') `
                -RunManifestPath (Join-Path $TestDrive 'w365-noanc-run.json') `
                -Cloud 'usgov' `
                -IncludeWin365 `
                -DryRun
        } | Should -Throw '*requires an Azure Network Connection*'

        {
            & $script:DeployScript `
                -EntraManifestPath $entraFile `
                -OutputPath (Join-Path $TestDrive 'w365-mhn.json') `
                -RunManifestPath (Join-Path $TestDrive 'w365-mhn-run.json') `
                -Cloud 'usgov' `
                -IncludeWin365 `
                -Win365NetworkMode 'mhn' `
                -Win365AncId '00000000-0000-0000-0000-000000000999' `
                -DryRun
        } | Should -Throw '*Microsoft Hosted Network (MHN) is not supported*'

        {
            & $script:DeployScript `
                -EntraManifestPath $entraFile `
                -OutputPath (Join-Path $TestDrive 'w365-fl.json') `
                -RunManifestPath (Join-Path $TestDrive 'w365-fl-run.json') `
                -Cloud 'usgov' `
                -IncludeWin365 `
                -Win365ProvisioningMode 'frontlineShared' `
                -Win365AncId '00000000-0000-0000-0000-000000000999' `
                -DryRun
        } | Should -Throw '*Frontline*'

        $okOut = Join-Path $TestDrive 'w365-ok.json'
        $okRun = Join-Path $TestDrive 'w365-ok-run.json'
        & $script:DeployScript `
            -EntraManifestPath $entraFile `
            -OutputPath $okOut `
            -RunManifestPath $okRun `
            -Cloud 'usgov' `
            -IncludeWin365 `
            -Win365AncId '00000000-0000-0000-0000-000000000999' `
            -DryRun

        $okManifest = Get-Content -LiteralPath $okOut -Raw -Encoding UTF8 | ConvertFrom-Json
        $okManifest.cloud | Should -Be 'usgov'
        $okManifest.win365.provisioningPolicyIds.Count | Should -Be 1
    }

    It 'routes Remove-AvdIntune.ps1 DELETE requests to https://graph.microsoft.us when cloud is usgov' {
        $runFile = Join-Path $TestDrive 'remove-usgov-run.json'
        $sampleRun = [ordered]@{
            schema            = 'avd-ops-intune-run-manifest/v1'
            stampPrefix       = '[avd-ops-contoso-prod]'
            environment       = 'prod'
            cloud             = 'usgov'
            complianceProfile = 'itar-cui'
            prefix            = 'contoso'
            resources         = @(
                [ordered]@{
                    resourceType = 'configurationPolicy'
                    id           = '00000000-0000-0000-0000-000000000501'
                    displayName  = '[avd-ops-contoso-prod] ITAR-CUI-SessionLockdown'
                    created      = $true
                }
            )
        }
        ($sampleRun | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $runFile -Encoding UTF8

        $deleteUris = [System.Collections.Generic.List[string]]::new()
        $invoker = {
            param($Method, $Uri, $Body)
            $deleteUris.Add($Uri)
            return [pscustomobject]@{ status = 'deleted' }
        }.GetNewClosure()

        $res = & $script:RemoveScript `
            -RunManifestPath $runFile `
            -Cloud 'usgov' `
            -DiscardLastCopy `
            -GraphInvoker $invoker `
            -Confirm:$false

        $res.cloud | Should -Be 'usgov'
        $res.complianceProfile | Should -Be 'itar-cui'
        $deleteUris.Count | Should -Be 1
        $deleteUris[0] | Should -Be 'https://graph.microsoft.us/beta/deviceManagement/configurationPolicies/00000000-0000-0000-0000-000000000501'
    }
}
