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
                all_setting_ids.add(s.get("settingId", ""))

        joined = " ".join(all_setting_ids)
        self.assertIn("fslogix", joined.lower(), "FSLogix settings must be present")
        self.assertIn("rdpshortpath_enable", joined.lower(), "RDP Shortpath setting must be present")
        self.assertIn("avd_mmr_enable", joined.lower(), "Multimedia redirection (MMR) must be present")
        self.assertIn("setdisconnectedtimelimit", joined.lower(), "Session timeout limit must be present")
        self.assertIn("deferqualityupdatesperiodindays", joined.lower(), "Windows Update ring settings must be present")

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
            self.assertEqual(len(intune_manifest["settingsCatalogProfiles"]), 3)
            self.assertTrue(intune_manifest["compliancePolicyId"])

            run_manifest = json.loads(run_path.read_text(encoding="utf-8"))
            self.assertEqual(run_manifest["stampPrefix"], "[avd-ops-contoso-dev]")
            self.assertEqual(len(run_manifest["resources"]), 4)
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
    deviceCompliancePolicies = @{{}}
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
            self.assertEqual(len(assign_calls), 8)
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


if __name__ == "__main__":
    unittest.main()
