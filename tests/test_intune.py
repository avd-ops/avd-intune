#!/usr/bin/env python3
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
"""Offline unit and integration tests for avd-intune scripts, profiles, and contracts."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT / "scripts"
PROFILES_DIR = ROOT / "profiles"

import sys

sys.path.insert(0, str(SCRIPTS_DIR))
import validate  # noqa: E402


SAMPLE_ENTRA_MANIFEST = {
    "schema": "avd-ops-entra-manifest/v1",
    "environment": "dev",
    "prefix": "contoso",
    "groups": {
        "avdUsersGroupId": "00000000-0000-0000-0000-000000000010",
        "avdAdminsGroupId": "00000000-0000-0000-0000-000000000011",
        "sessionHostsDynamicGroupId": "00000000-0000-0000-0000-000000000012",
        "breakGlassExcludeGroupId": "00000000-0000-0000-0000-000000000013",
    },
    "conditionalAccess": [
        {
            "displayName": "[avd-ops-contoso-dev] AVD MFA Policy",
            "state": "enabledForReportingButNotEnforced",
            "policyId": "00000000-0000-0000-0000-000000000020",
        }
    ],
    "entraKerberosReady": True,
}


class TestAvdIntune(unittest.TestCase):
    """Test suite for avd-intune validation, deployment, idempotency, and teardown."""

    def test_repository_validation_passes(self) -> None:
        errors = validate.run_validation()
        self.assertEqual(errors, [], f"Expected zero validation errors, got: {errors}")

    def test_settings_catalog_covers_all_required_areas(self) -> None:
        sc_dir = PROFILES_DIR / "settings-catalog"
        files = sorted(sc_dir.glob("*.json"))
        self.assertGreaterEqual(len(files), 3)

        all_setting_ids: set[str] = set()
        for f in files:
            data = json.loads(f.read_text(encoding="utf-8"))
            for s in data.get("settings", []):
                if "settingId" in s:
                    all_setting_ids.add(s["settingId"])
                elif "settingInstance" in s:
                    all_setting_ids.add(s["settingInstance"].get("settingDefinitionId", ""))
        oma_dir = PROFILES_DIR / "custom-oma-uri"
        if oma_dir.is_dir():
            for f in sorted(oma_dir.glob("*.json")):
                data = json.loads(f.read_text(encoding="utf-8"))
                for o in data.get("omaSettings", []):
                    if "omaUri" in o:
                        all_setting_ids.add(o["omaUri"])

        joined = " ".join(all_setting_ids)
        self.assertIn("fslogix", joined.lower(), "FSLogix settings must be present")
        self.assertIn("ts_client_turn_off_udp", joined.lower(), "RDP UDP/Shortpath setting must be present")
        self.assertIn("ts_sessions_disconnected_timeout_2", joined.lower(), "Session timeout limit must be present")
        self.assertIn("deferqualityupdatesperiodindays", joined.lower(), "Windows Update ring settings must be present")
        self.assertIn("defender_allowrealtimemonitoring", joined.lower(), "Defender Antivirus baseline must be present")
        self.assertIn("defender_excludedpaths", joined.lower(), "Defender FSLogix/AVD exclusions must be present")
        self.assertIn("defender_attacksurfacereductionrules", joined.lower(), "Defender ASR rules must be present")
        self.assertIn("profilesroamidentity", joined.lower(), "FSLogix RoamIdentity off setting must be present")

    def test_manifest_schema_validation_rejects_invalid_payloads(self) -> None:
        schema = json.loads((ROOT / "contracts" / "intune-manifest.schema.json").read_text(encoding="utf-8"))
        valid_payload = {
            "schema": "avd-ops-intune-manifest/v1",
            "environment": "dev",
            "targetDeviceGroupId": "00000000-0000-0000-0000-000000000012",
            "settingsCatalogProfiles": ["00000000-0000-0000-0000-000000000101"],
            "compliancePolicyId": "00000000-0000-0000-0000-000000000201",
        }
        self.assertEqual(validate.validate_intune_manifest(valid_payload, "valid", schema), [])

        bad_extra = dict(valid_payload, extraField="not-allowed")
        errs = validate.validate_intune_manifest(bad_extra, "bad_extra", schema)
        self.assertTrue(any("unexpected property 'extraField'" in e for e in errs))

        bad_env = dict(valid_payload, environment="staging")
        errs = validate.validate_intune_manifest(bad_env, "bad_env", schema)
        self.assertTrue(any("environment" in e for e in errs))

    def test_deploy_dry_run_emits_valid_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            intune_path = tmp_path / "intune-manifest.json"
            run_path = tmp_path / "intune-run-manifest.json"

            entra_path.write_text(json.dumps(SAMPLE_ENTRA_MANIFEST), encoding="utf-8")

            proc = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Deploy-AvdIntune.ps1"),
                    "-EntraManifestPath",
                    str(entra_path),
                    "-OutputPath",
                    str(intune_path),
                    "-RunManifestPath",
                    str(run_path),
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Deploy-AvdIntune.ps1 failed:\n{proc.stderr}\n{proc.stdout}")
            self.assertTrue(intune_path.is_file())
            self.assertTrue(run_path.is_file())

            intune_manifest = json.loads(intune_path.read_text(encoding="utf-8"))
            self.assertEqual(intune_manifest["schema"], "avd-ops-intune-manifest/v1")
            self.assertEqual(intune_manifest["environment"], "dev")
            self.assertEqual(
                intune_manifest["targetDeviceGroupId"],
                "00000000-0000-0000-0000-000000000012",
            )
            self.assertEqual(len(intune_manifest["settingsCatalogProfiles"]), 5)
            self.assertEqual(len(intune_manifest["deviceConfigurationProfiles"]), 1)
            self.assertTrue(intune_manifest["compliancePolicyId"])

            run_manifest = json.loads(run_path.read_text(encoding="utf-8"))
            self.assertEqual(run_manifest["stampPrefix"], "[avd-ops-contoso-dev]")
            self.assertEqual(len(run_manifest["resources"]), 7)
            for res in run_manifest["resources"]:
                self.assertTrue(res["displayName"].startswith("[avd-ops-contoso-dev] "))
                self.assertTrue(res["created"])
                self.assertEqual(res["assignedTo"], "00000000-0000-0000-0000-000000000012")

    def test_idempotent_crud_and_assignments_with_mock_graph(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            intune_path = tmp_path / "intune-manifest.json"
            run_path = tmp_path / "intune-run-manifest.json"
            calls_path = tmp_path / "graph-calls.json"
            entra_path.write_text(json.dumps(SAMPLE_ENTRA_MANIFEST), encoding="utf-8")

            ps_test_script = tmp_path / "run-idempotency.ps1"
            ps_test_script.write_text(
                f"""
$ErrorActionPreference = 'Stop'
$store = @{{
    configurationPolicies = @{{}}
    deviceConfigurations = @{{}}
    deviceCompliancePolicies = @{{}}
    secureByDefault = $false
}}
$calls = [System.Collections.Generic.List[object]]::new()
$state = @{{ counter = 100 }}

$invoker = ({{
    param($Method, $Uri, $Body)
    $calls.Add([ordered]@{{
        method = $Method
        uri    = $Uri
        body   = $Body
    }})
    if ($Method -eq 'GET' -and $Uri -like '*/subscribedSkus*') {{
        return [pscustomobject]@{{
            value = @([pscustomobject]@{{
                skuPartNumber = 'SPE_E5'
                capabilityStatus = 'Enabled'
                servicePlans = @([pscustomobject]@{{
                    servicePlanName = 'INTUNE_A'
                    provisioningStatus = 'Success'
                }})
            }})
        }}
    }}
    if ($Method -eq 'GET' -and $Uri -like '*/deviceEnrollmentConfigurations*') {{
        return [pscustomobject]@{{
            value = @([pscustomobject]@{{
                id = '00000000-0000-0000-0000-000000000001'
                displayName = 'Default Restrictions'
                windowsRestriction = [pscustomobject]@{{ platformBlocked = $false }}
            }})
        }}
    }}
    if ($Method -eq 'GET' -and $Uri -like '*/configurationPolicies?*$filter=*') {{
        $vals = @($store.configurationPolicies.Values)
        return [pscustomobject]@{{ value = $vals }}
    }}
    if ($Method -eq 'POST' -and $Uri -eq 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies') {{
        $state.counter++
        $id = "00000000-0000-0000-0000-000000000$($state.counter)"
        $obj = [pscustomobject]@{{ id = $id; name = [string]$Body['name'] }}
        $store.configurationPolicies[$id] = $obj
        return $obj
    }}
    if ($Method -eq 'PATCH' -and $Uri -like '*/configurationPolicies/*') {{
        return [pscustomobject]@{{ status = 'updated' }}
    }}
    if ($Method -eq 'GET' -and $Uri -like '*/deviceConfigurations?*$filter=*') {{
        $vals = @($store.deviceConfigurations.Values)
        return [pscustomobject]@{{ value = $vals }}
    }}
    if ($Method -eq 'POST' -and $Uri -eq 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations') {{
        $state.counter++
        $id = "00000000-0000-0000-0000-000000000$($state.counter)"
        $obj = [pscustomobject]@{{ id = $id; displayName = [string]$Body['displayName'] }}
        $store.deviceConfigurations[$id] = $obj
        return $obj
    }}
    if ($Method -eq 'PATCH' -and $Uri -like '*/deviceConfigurations/*') {{
        return [pscustomobject]@{{ status = 'updated' }}
    }}
    if ($Method -eq 'GET' -and $Uri -like '*/deviceCompliancePolicies?*$filter=*') {{
        $vals = @($store.deviceCompliancePolicies.Values)
        return [pscustomobject]@{{ value = $vals }}
    }}
    if ($Method -eq 'POST' -and $Uri -eq 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies') {{
        $state.counter++
        $id = "00000000-0000-0000-0000-000000000$($state.counter)"
        $obj = [pscustomobject]@{{ id = $id; displayName = [string]$Body['displayName'] }}
        $store.deviceCompliancePolicies[$id] = $obj
        return $obj
    }}
    if ($Method -eq 'PATCH' -and $Uri -like '*/deviceCompliancePolicies/*') {{
        return [pscustomobject]@{{ status = 'updated' }}
    }}
    if ($Method -eq 'GET' -and $Uri -like '*/deviceManagement/settings*') {{
        return [pscustomobject]@{{ secureByDefault = $store.secureByDefault }}
    }}
    if ($Method -eq 'PATCH' -and $Uri -like '*/deviceManagement/settings*') {{
        $store.secureByDefault = [bool]$Body['secureByDefault']
        return [pscustomobject]@{{ secureByDefault = $store.secureByDefault }}
    }}
    if ($Method -eq 'POST' -and $Uri -like '*/assign') {{
        return [pscustomobject]@{{ status = 'assigned' }}
    }}
    throw "Unexpected Graph call: $Method $Uri"
}}).GetNewClosure()

& '{SCRIPTS_DIR / "Deploy-AvdIntune.ps1"}' `
    -EntraManifestPath '{entra_path}' `
    -OutputPath '{intune_path}' `
    -RunManifestPath '{run_path}' `
    -GraphInvoker $invoker

$run1 = Get-Content -LiteralPath '{run_path}' -Raw | ConvertFrom-Json

& '{SCRIPTS_DIR / "Deploy-AvdIntune.ps1"}' `
    -EntraManifestPath '{entra_path}' `
    -OutputPath '{intune_path}' `
    -RunManifestPath '{run_path}' `
    -GraphInvoker $invoker

$run2 = Get-Content -LiteralPath '{run_path}' -Raw | ConvertFrom-Json

[ordered]@{{
    run1  = $run1
    run2  = $run2
    calls = $calls
}} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath '{calls_path}' -Encoding UTF8
""",
                encoding="utf-8",
            )

            proc = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(ps_test_script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Idempotency script failed:\n{proc.stderr}\n{proc.stdout}")

            result = json.loads(calls_path.read_text(encoding="utf-8"))
            run1_resources = result["run1"]["resources"]
            run2_resources = result["run2"]["resources"]

            self.assertTrue(all(r["created"] is True for r in run1_resources))
            self.assertTrue(all(r["created"] is False for r in run2_resources))
            self.assertEqual(
                [r["id"] for r in run1_resources],
                [r["id"] for r in run2_resources],
            )

            assign_calls = [c for c in result["calls"] if c["uri"].endswith("/assign")]
            self.assertEqual(len(assign_calls), 14)
            settings_patches = [
                c for c in result["calls"]
                if c["method"] == "PATCH" and c["uri"].endswith("/deviceManagement/settings")
            ]
            self.assertEqual(len(settings_patches), 1)
            self.assertTrue(settings_patches[0]["body"]["secureByDefault"])
            self.assertTrue(result["run1"]["tenantComplianceSecureByDefault"])
            for ac in assign_calls:
                target = ac["body"]["assignments"][0]["target"]
                self.assertEqual(target["@odata.type"], "#microsoft.graph.groupAssignmentTarget")
                self.assertEqual(target["groupId"], "00000000-0000-0000-0000-000000000012")

    def test_preflight_fails_when_license_missing_or_enrollment_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            entra_path.write_text(json.dumps(SAMPLE_ENTRA_MANIFEST), encoding="utf-8")

            no_license_script = tmp_path / "no-license.ps1"
            no_license_script.write_text(
                f"""
$invoker = {{
    param($Method, $Uri, $Body)
    return [pscustomobject]@{{ value = @() }}
}}
& '{SCRIPTS_DIR / "Deploy-AvdIntune.ps1"}' -EntraManifestPath '{entra_path}' -GraphInvoker $invoker
""",
                encoding="utf-8",
            )
            proc = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(no_license_script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Intune license preflight failed", proc.stderr + proc.stdout)

            blocked_enrollment_script = tmp_path / "blocked-enrollment.ps1"
            blocked_enrollment_script.write_text(
                f"""
$invoker = {{
    param($Method, $Uri, $Body)
    if ($Uri -like '*/subscribedSkus*') {{
        return [pscustomobject]@{{
            value = @([pscustomobject]@{{
                capabilityStatus = 'Enabled'
                servicePlans = @([pscustomobject]@{{
                    servicePlanName = 'INTUNE_A'
                    provisioningStatus = 'Success'
                }})
            }})
        }}
    }}
    return [pscustomobject]@{{
        value = @([pscustomobject]@{{
            id = '00000000-0000-0000-0000-000000000099'
            displayName = 'Block Windows'
            windowsRestriction = [pscustomobject]@{{ platformBlocked = $true }}
        }})
    }}
}}
& '{SCRIPTS_DIR / "Deploy-AvdIntune.ps1"}' -EntraManifestPath '{entra_path}' -GraphInvoker $invoker
""",
                encoding="utf-8",
            )
            proc2 = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(blocked_enrollment_script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc2.returncode, 0)
            self.assertIn("MDM enrollment check failed", proc2.stderr + proc2.stdout)

    def test_remove_avd_intune_enforces_discard_last_copy_and_selective_delete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            run_path = tmp_path / "intune-run-manifest.json"
            out_path = tmp_path / "teardown-result.json"

            sample_run = {
                "schema": "avd-ops-intune-run-manifest/v1",
                "stampPrefix": "[avd-ops-contoso-dev]",
                "environment": "dev",
                "prefix": "contoso",
                "targetDeviceGroupId": "00000000-0000-0000-0000-000000000012",
                "avdUsersGroupId": "00000000-0000-0000-0000-000000000010",
                "resources": [
                    {
                        "resourceType": "configurationPolicy",
                        "id": "00000000-0000-0000-0000-000000000101",
                        "displayName": "[avd-ops-contoso-dev] Created Baseline",
                        "created": True,
                    },
                    {
                        "resourceType": "configurationPolicy",
                        "id": "00000000-0000-0000-0000-000000000102",
                        "displayName": "[avd-ops-contoso-dev] Preexisting Baseline",
                        "created": False,
                    },
                    {
                        "resourceType": "deviceCompliancePolicy",
                        "id": "00000000-0000-0000-0000-000000000103",
                        "displayName": "[other-prefix] Unrelated Policy",
                        "created": True,
                    },
                    {
                        "resourceType": "deviceCompliancePolicy",
                        "id": "00000000-0000-0000-0000-000000000104",
                        "displayName": "[avd-ops-contoso-dev] Created Compliance",
                        "created": True,
                    },
                ],
            }
            run_path.write_text(json.dumps(sample_run), encoding="utf-8")

            # 1. Must fail without -DiscardLastCopy
            proc_fail = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Remove-AvdIntune.ps1"),
                    "-RunManifestPath",
                    str(run_path),
                    "-DryRun",
                    "-Confirm:$false",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_fail.returncode, 0)
            self.assertIn("-DiscardLastCopy", proc_fail.stderr + proc_fail.stdout)

            # 2. Succeeds with -DiscardLastCopy and only deletes created=true matching prefix
            teardown_script = tmp_path / "run-teardown.ps1"
            teardown_script.write_text(
                f"""
$deletedUris = [System.Collections.Generic.List[string]]::new()
$invoker = {{
    param($Method, $Uri, $Body)
    $deletedUris.Add("$Method $Uri")
    return [pscustomobject]@{{ status = 'deleted' }}
}}
$summary = & '{SCRIPTS_DIR / "Remove-AvdIntune.ps1"}' `
    -RunManifestPath '{run_path}' `
    -DiscardLastCopy `
    -GraphInvoker $invoker `
    -Confirm:$false

[ordered]@{{
    summary     = $summary
    deletedUris = $deletedUris
}} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath '{out_path}' -Encoding UTF8
""",
                encoding="utf-8",
            )
            proc_ok = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(teardown_script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc_ok.returncode, 0, f"Teardown failed:\n{proc_ok.stderr}\n{proc_ok.stdout}")
            teardown_data = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertEqual(
                teardown_data["summary"]["removedIds"],
                [
                    "00000000-0000-0000-0000-000000000101",
                    "00000000-0000-0000-0000-000000000104",
                ],
            )
            self.assertEqual(
                teardown_data["summary"]["skippedIds"],
                [
                    "00000000-0000-0000-0000-000000000102",
                    "00000000-0000-0000-0000-000000000103",
                ],
            )
            self.assertEqual(len(teardown_data["deletedUris"]), 2)

    def test_deploy_with_assignment_filters_and_win365(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            intune_path = tmp_path / "intune-manifest.json"
            run_path = tmp_path / "intune-run-manifest.json"

            entra_path.write_text(json.dumps(SAMPLE_ENTRA_MANIFEST), encoding="utf-8")

            proc = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Deploy-AvdIntune.ps1"),
                    "-EntraManifestPath",
                    str(entra_path),
                    "-OutputPath",
                    str(intune_path),
                    "-RunManifestPath",
                    str(run_path),
                    "-DeployAssignmentFilters",
                    "-IncludeWin365",
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Deploy-AvdIntune.ps1 -IncludeWin365 failed:\n{proc.stderr}\n{proc.stdout}")
            intune_manifest = json.loads(intune_path.read_text(encoding="utf-8"))
            self.assertIn("assignmentFilters", intune_manifest)
            self.assertEqual(
                set(intune_manifest["assignmentFilters"].keys()),
                {"avd-multisession", "avd-personal", "win365-cloudpc", "physical-desktop"},
            )
            self.assertIn("win365", intune_manifest)
            self.assertEqual(len(intune_manifest["win365"]["provisioningPolicyIds"]), 1)
            self.assertEqual(len(intune_manifest["win365"]["userSettingsIds"]), 1)

            run_manifest = json.loads(run_path.read_text(encoding="utf-8"))
            self.assertEqual(len(run_manifest["resources"]), 13)
            resource_types = [r["resourceType"] for r in run_manifest["resources"]]
            self.assertEqual(resource_types.count("assignmentFilter"), 4)
            self.assertEqual(resource_types.count("cloudPcProvisioningPolicy"), 1)
            self.assertEqual(resource_types.count("cloudPcUserSetting"), 1)

    def test_c26_cloud_environments_contract_matches_avd_assess(self) -> None:
        c26_path = ROOT / "contracts" / "cloud-environments.json"
        self.assertTrue(c26_path.is_file(), "contracts/cloud-environments.json must exist")
        c26 = json.loads(c26_path.read_text(encoding="utf-8"))
        self.assertEqual(c26["schema"], "avd-cloud-environments/v1")
        self.assertEqual(c26["clouds"]["commercial"]["graphEndpoint"], "https://graph.microsoft.com")
        self.assertEqual(c26["clouds"]["usgov"]["graphEndpoint"], "https://graph.microsoft.us")
        self.assertEqual(c26["clouds"]["usgov"]["entraEnvironment"], "USGov")
        self.assertFalse(c26["clouds"]["usgov"]["capabilities"]["win365MicrosoftHostedNetwork"])
        self.assertTrue(c26["clouds"]["usgov"]["capabilities"]["win365AzureNetworkConnection"])
        self.assertFalse(c26["clouds"]["usgov"]["capabilities"]["win365Frontline"])

    def test_usgov_deploy_routes_to_graph_microsoft_us_and_deploys_itar_cui_lockdown(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            intune_path = tmp_path / "intune-manifest.json"
            run_path = tmp_path / "intune-run-manifest.json"
            uris_path = tmp_path / "recorded-uris.json"

            usgov_entra = dict(SAMPLE_ENTRA_MANIFEST, cloud="usgov", complianceProfile="itar-cui")
            entra_path.write_text(json.dumps(usgov_entra), encoding="utf-8")

            ps_script = tmp_path / "run-usgov.ps1"
            ps_script.write_text(
                f"""
$ErrorActionPreference = 'Stop'
$uris = [System.Collections.Generic.List[string]]::new()
$invoker = {{
    param($Method, $Uri, $Body)
    $uris.Add($Uri)
    if ($Method -eq 'GET' -and $Uri -like '*/subscribedSkus*') {{
        return [pscustomobject]@{{
            value = @([pscustomobject]@{{
                skuPartNumber = 'SPE_E5_GOV'
                capabilityStatus = 'Enabled'
                servicePlans = @([pscustomobject]@{{
                    servicePlanName = 'INTUNE_A'
                    provisioningStatus = 'Success'
                }})
            }})
        }}
    }}
    if ($Method -eq 'GET') {{
        return [pscustomobject]@{{ value = @() }}
    }}
    if ($Method -eq 'POST' -and $Uri -notlike '*/assign') {{
        return [pscustomobject]@{{ id = [guid]::NewGuid().ToString() }}
    }}
    return [pscustomobject]@{{ status = 'ok' }}
}}.GetNewClosure()

& '{SCRIPTS_DIR / "Deploy-AvdIntune.ps1"}' `
    -EntraManifestPath '{entra_path}' `
    -OutputPath '{intune_path}' `
    -RunManifestPath '{run_path}' `
    -Cloud 'usgov' `
    -GraphInvoker $invoker

$uris | ConvertTo-Json | Set-Content -LiteralPath '{uris_path}' -Encoding UTF8
""",
                encoding="utf-8",
            )
            proc = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(ps_script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"USGov deploy failed:\n{proc.stderr}\n{proc.stdout}")

            recorded_uris = json.loads(uris_path.read_text(encoding="utf-8"))
            self.assertGreater(len(recorded_uris), 0)
            for uri in recorded_uris:
                self.assertTrue(
                    uri.startswith("https://graph.microsoft.us/"),
                    f"Expected graph.microsoft.us URI in usgov, got {uri}",
                )

            intune_manifest = json.loads(intune_path.read_text(encoding="utf-8"))
            self.assertEqual(intune_manifest["cloud"], "usgov")
            self.assertEqual(intune_manifest["complianceProfile"], "itar-cui")
            self.assertEqual(len(intune_manifest["settingsCatalogProfiles"]), 6)

            run_manifest = json.loads(run_path.read_text(encoding="utf-8"))
            self.assertEqual(run_manifest["cloud"], "usgov")
            self.assertEqual(run_manifest["complianceProfile"], "itar-cui")
            source_files = [r["sourceFile"] for r in run_manifest["resources"]]
            self.assertIn("itar-cui-session-lockdown.json", source_files)

    def test_cross_cloud_mismatch_and_win365_gov_anc_enforcement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            usgov_entra = dict(SAMPLE_ENTRA_MANIFEST, cloud="usgov")
            entra_path.write_text(json.dumps(usgov_entra), encoding="utf-8")

            # 1. Cross-cloud mismatch between entra-manifest.json (usgov) and -Cloud commercial
            proc_mismatch = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Deploy-AvdIntune.ps1"),
                    "-EntraManifestPath",
                    str(entra_path),
                    "-OutputPath",
                    str(tmp_path / "out1.json"),
                    "-RunManifestPath",
                    str(tmp_path / "run1.json"),
                    "-Cloud",
                    "commercial",
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_mismatch.returncode, 0)
            self.assertIn("Cloud boundary mismatch", proc_mismatch.stderr + proc_mismatch.stdout)

            # 2. Win365 in usgov without ANC fails closed
            proc_no_anc = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Deploy-AvdIntune.ps1"),
                    "-EntraManifestPath",
                    str(entra_path),
                    "-OutputPath",
                    str(tmp_path / "out2.json"),
                    "-RunManifestPath",
                    str(tmp_path / "run2.json"),
                    "-Cloud",
                    "usgov",
                    "-IncludeWin365",
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_no_anc.returncode, 0)
            self.assertIn("Azure Network Connection", proc_no_anc.stderr + proc_no_anc.stdout)

            # 3. Win365 in usgov with MHN fails closed
            proc_mhn = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Deploy-AvdIntune.ps1"),
                    "-EntraManifestPath",
                    str(entra_path),
                    "-OutputPath",
                    str(tmp_path / "out3.json"),
                    "-RunManifestPath",
                    str(tmp_path / "run3.json"),
                    "-Cloud",
                    "usgov",
                    "-IncludeWin365",
                    "-Win365NetworkMode",
                    "mhn",
                    "-Win365AncId",
                    "00000000-0000-0000-0000-000000000999",
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_mhn.returncode, 0)
            self.assertIn("Microsoft Hosted Network (MHN) is not supported", proc_mhn.stderr + proc_mhn.stdout)

            # 4. Win365 in usgov with Frontline Shared fails closed
            proc_fl = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Deploy-AvdIntune.ps1"),
                    "-EntraManifestPath",
                    str(entra_path),
                    "-OutputPath",
                    str(tmp_path / "out4.json"),
                    "-RunManifestPath",
                    str(tmp_path / "run4.json"),
                    "-Cloud",
                    "usgov",
                    "-IncludeWin365",
                    "-Win365ProvisioningMode",
                    "frontlineShared",
                    "-Win365AncId",
                    "00000000-0000-0000-0000-000000000999",
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_fl.returncode, 0)
            self.assertIn("Frontline", proc_fl.stderr + proc_fl.stdout)

    def test_usgov_cloud_ps1_suite_passes(self) -> None:
        proc = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ROOT / "tests" / "UsGovCloud.Tests.ps1")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"tests/UsGovCloud.Tests.ps1 failed:\n{proc.stderr}\n{proc.stdout}",
        )

    def test_defender_policies_target_vdi_filters_without_physical_desktop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            entra_path = tmp_path / "entra-manifest.json"
            intune_path = tmp_path / "intune-manifest.json"
            run_path = tmp_path / "intune-run-manifest.json"
            calls_path = tmp_path / "graph-calls.json"
            entra_path.write_text(json.dumps(SAMPLE_ENTRA_MANIFEST), encoding="utf-8")

            ps_script = tmp_path / "run-defender-filters.ps1"
            ps_script.write_text(
                f"""
$ErrorActionPreference = 'Stop'
$calls = [System.Collections.Generic.List[object]]::new()
$state = @{{ counter = 100 }}
$invoker = ({{
    param($Method, $Uri, $Body)
    $calls.Add([ordered]@{{ method = $Method; uri = $Uri; body = $Body }})
    if ($Method -eq 'GET' -and $Uri -like '*/subscribedSkus*') {{
        return [pscustomobject]@{{
            value = @([pscustomobject]@{{
                skuPartNumber = 'SPE_E5'
                capabilityStatus = 'Enabled'
                servicePlans = @([pscustomobject]@{{
                    servicePlanName = 'INTUNE_A'
                    provisioningStatus = 'Success'
                }})
            }})
        }}
    }}
    if ($Method -eq 'GET') {{
        return [pscustomobject]@{{ value = @() }}
    }}
    if ($Method -eq 'POST' -and $Uri -notlike '*/assign') {{
        $state.counter++
        $id = "00000000-0000-0000-0000-000000000$($state.counter)"
        return [pscustomobject]@{{ id = $id }}
    }}
    return [pscustomobject]@{{ status = 'ok' }}
}}).GetNewClosure()

& '{SCRIPTS_DIR / "Deploy-AvdIntune.ps1"}' `
    -EntraManifestPath '{entra_path}' `
    -OutputPath '{intune_path}' `
    -RunManifestPath '{run_path}' `
    -DeployAssignmentFilters `
    -GraphInvoker $invoker

$calls | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath '{calls_path}' -Encoding UTF8
""",
                encoding="utf-8",
            )
            proc = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(ps_script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Defender filter deploy failed:\n{proc.stderr}\n{proc.stdout}")

            intune_manifest = json.loads(intune_path.read_text(encoding="utf-8"))
            filters = intune_manifest["assignmentFilters"]
            expected_vdi_filters = {
                filters["avd-multisession"],
                filters["avd-personal"],
                filters["win365-cloudpc"],
            }
            physical_filter_id = filters["physical-desktop"]

            run_manifest = json.loads(run_path.read_text(encoding="utf-8"))
            defender_ids = {
                r["id"]
                for r in run_manifest["resources"]
                if r["sourceFile"] in {
                    "avd-defender-antivirus-baseline.json",
                    "avd-defender-fslogix-exclusions.json",
                    "avd-defender-asr-rules.json",
                }
            }
            self.assertEqual(len(defender_ids), 3)

            calls = json.loads(calls_path.read_text(encoding="utf-8"))
            for policy_id in defender_ids:
                assign_call = next(
                    c for c in calls if c["uri"].endswith(f"/configurationPolicies/{policy_id}/assign")
                )
                assignments = assign_call["body"]["assignments"]
                group_ids = [a["target"]["groupId"] for a in assignments]
                self.assertEqual(len(group_ids), len(set(group_ids)), "Intune /assign rejects duplicate groupId targets")
                self.assertEqual(len(assignments), 1)
                self.assertEqual(assignments[0]["target"]["deviceAndAppManagementAssignmentFilterId"], physical_filter_id)
                self.assertEqual(assignments[0]["target"]["deviceAndAppManagementAssignmentFilterType"], "exclude")

    def test_evergreen_app_manifest_and_sync_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "evergreen-apps-resolved.json"
            proc = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(SCRIPTS_DIR / "Sync-EvergreenApps.ps1"),
                    "-OutputPath",
                    str(out_path),
                    "-DryRun",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Sync-EvergreenApps.ps1 failed:\n{proc.stderr}\n{proc.stdout}")
            data = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertEqual(data["schema"], "avd-ops-evergreen-apps/v1")
            self.assertGreaterEqual(len(data["apps"]), 5)
            for app in data["apps"]:
                self.assertEqual(app["installContext"], "system")
                self.assertEqual(app["intent"], "required")
                self.assertEqual(app["targetType"], "deviceGroup")

    def test_sync_evergreen_apps_filters_and_rejects_empty_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "evergreen-apps-resolved.json"
            wrapper = Path(tmp) / "run_sync.ps1"
            wrapper.write_text(
                f"""
$resolver = {{
    param($app)
    switch ($app.evergreenApp) {{
        'MicrosoftEdge' {{
            @(
                [pscustomobject]@{{ Architecture='x86'; Channel='Stable'; Release='Enterprise'; Version='1.0'; URI='https://example.invalid/x86.msi' }},
                [pscustomobject]@{{ Architecture='x64'; Channel='Stable'; Release='Enterprise'; Version='130.0.1'; URI='https://example.invalid/edge-x64.msi'; Sha256='abc123' }}
            )
        }}
        'MicrosoftTeams' {{
            @([pscustomobject]@{{ Architecture='x64'; Type='msi'; Version='24277.0'; URI='https://example.invalid/teams.msi' }})
        }}
        'MicrosoftFSLogixApps' {{
            @([pscustomobject]@{{ Channel='Production'; Version='2.9.8884'; URI='https://example.invalid/fslogix.zip' }})
        }}
        'MicrosoftRdcwebrtcredirdor' {{
            @([pscustomobject]@{{ Architecture='x64'; Version='1.50.0'; URI='https://example.invalid/webrtc.msi' }})
        }}
        'VcRedist' {{
            @([pscustomobject]@{{ Release='2022'; Architecture='x64'; Version='14.40.33810'; URI='https://example.invalid/vcredist.exe' }})
        }}
    }}
}}
& '{SCRIPTS_DIR / "Sync-EvergreenApps.ps1"}' -OutputPath '{out_path}' -AppResolver $resolver
""",
                encoding="utf-8",
            )
            proc = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(wrapper)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Filtered sync failed:\n{proc.stderr}\n{proc.stdout}")
            data = json.loads(out_path.read_text(encoding="utf-8"))
            edge = next(a for a in data["apps"] if a["id"] == "microsoft-edge-enterprise")
            self.assertEqual(edge["version"], "130.0.1")
            self.assertEqual(edge["sha256"], "abc123")

            bad_wrapper = Path(tmp) / "run_bad.ps1"
            bad_wrapper.write_text(
                f"& '{SCRIPTS_DIR / 'Sync-EvergreenApps.ps1'}' -OutputPath '{out_path}' -AppResolver {{ param($app) @() }}",
                encoding="utf-8",
            )
            bad_proc = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(bad_wrapper)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(bad_proc.returncode, 0, "Expected non-zero exit when no items match evergreenFilter")

    def test_persistent_host_wau_manifest(self) -> None:
        wau_path = PROFILES_DIR / "apps" / "persistent-host-wau.json"
        self.assertTrue(wau_path.exists(), "persistent-host-wau.json must exist")
        wau = json.loads(wau_path.read_text(encoding="utf-8"))
        self.assertEqual(wau["upstream"]["license"], "MIT")
        self.assertIn("avd-personal", wau["targetFilters"])
        self.assertIn("win365-cloudpc", wau["targetFilters"])
        self.assertNotIn("avd-multisession", wau["targetFilters"])
        self.assertIn("avd-multisession", wau["excludedFilters"])
        self.assertEqual(len(wau["apps"]), 1)
        self.assertEqual(wau["apps"][0]["id"], "winget-autoupdate")
        self.assertEqual(wau["apps"][0]["installContext"], "system")
        self.assertEqual(wau["apps"][0]["intent"], "required")
        self.assertEqual(wau["apps"][0]["targetType"], "deviceGroup")
        self.assertEqual(wau["psadtInterop"]["mode"], "invoke-only")


    def test_live_graph_filter_and_defender_schema_guards(self) -> None:
        deploy_src = (ROOT / "scripts" / "Deploy-AvdIntune.ps1").read_text(encoding="utf-8")
        self.assertNotIn("assignmentFilters?`$filter=", deploy_src)
        self.assertIn("EscapeDataString(\"name eq '$escapedName'\")", deploy_src)
        self.assertIn("$patchPayload = [ordered]@{", deploy_src)

        phys = json.loads((ROOT / "profiles" / "filters" / "physical-desktop.json").read_text(encoding="utf-8"))
        self.assertNotIn("not (device.model", phys["rule"])

        defender = json.loads(
            (ROOT / "profiles" / "settings-catalog" / "avd-defender-antivirus-baseline.json").read_text(encoding="utf-8")
        )
        by_id = {s["settingId"]: s["value"] for s in defender["settings"]}
        self.assertIsInstance(by_id["device_vendor_msft_policy_config_defender_allowrealtimemonitoring"], str)
        self.assertNotIn("device_vendor_msft_policy_config_defender_randomizescheduledtasktimes", by_id)


if __name__ == "__main__":
    unittest.main()


