#!/usr/bin/env python3
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
"""Validate all JSON templates, contract schemas, and no-leak guardrails in this repository."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
SECRET_PATTERNS = (
    re.compile(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----"),
    re.compile(r"(?i)\b(?:client_secret|api_key|access_token)\s*[:=]\s*['\"][A-Za-z0-9_\-~.]{16,}['\"]"),
)
ALLOWED_DOMAINS = ("example.com", "contoso.com", "users.noreply.github.com")


def validate_intune_manifest(data: Any, label: str, schema: dict[str, Any]) -> list[str]:
    """Validate an intune-manifest.json payload against contracts/intune-manifest.schema.json."""
    errs: list[str] = []
    if not isinstance(data, dict):
        return [f"{label}: manifest root must be a JSON object"]

    required_fields = schema.get(
        "required",
        [
            "schema",
            "environment",
            "targetDeviceGroupId",
            "settingsCatalogProfiles",
            "compliancePolicyId",
        ],
    )
    allowed_props = set(schema.get("properties", {}).keys())

    for req in required_fields:
        if req not in data:
            errs.append(f"{label}: missing required field '{req}'")

    if schema.get("additionalProperties") is False and allowed_props:
        for key in data:
            if key not in allowed_props:
                errs.append(f"{label}: unexpected property '{key}'")

    if "schema" in data and data["schema"] != "avd-ops-intune-manifest/v1":
        errs.append(
            f"{label}: 'schema' must equal 'avd-ops-intune-manifest/v1' (got {data['schema']!r})"
        )

    if "environment" in data and data["environment"] not in ("dev", "test", "prod"):
        errs.append(
            f"{label}: 'environment' must be one of dev, test, prod (got {data['environment']!r})"
        )

    if "cloud" in data and data["cloud"] not in ("commercial", "usgov"):
        errs.append(
            f"{label}: 'cloud' must be one of commercial, usgov (got {data['cloud']!r})"
        )

    if "complianceProfile" in data and data["complianceProfile"] not in ("standard", "itar-cui"):
        errs.append(
            f"{label}: 'complianceProfile' must be one of standard, itar-cui (got {data['complianceProfile']!r})"
        )

    if "targetDeviceGroupId" in data:
        if not isinstance(data["targetDeviceGroupId"], str) or not data["targetDeviceGroupId"].strip():
            errs.append(f"{label}: 'targetDeviceGroupId' must be a non-empty string")

    if "settingsCatalogProfiles" in data:
        profiles = data["settingsCatalogProfiles"]
        if not isinstance(profiles, list) or not profiles:
            errs.append(f"{label}: 'settingsCatalogProfiles' must be a non-empty array of strings")
        elif not all(isinstance(item, str) and item.strip() for item in profiles):
            errs.append(f"{label}: all items in 'settingsCatalogProfiles' must be non-empty strings")

    if "compliancePolicyId" in data:
        if not isinstance(data["compliancePolicyId"], str) or not data["compliancePolicyId"].strip():
            errs.append(f"{label}: 'compliancePolicyId' must be a non-empty string")

    if "assignmentFilters" in data:
        af = data["assignmentFilters"]
        if not isinstance(af, dict):
            errs.append(f"{label}: 'assignmentFilters' must be a JSON object")
        else:
            for fk, fv in af.items():
                if not isinstance(fv, str) or not fv.strip():
                    errs.append(f"{label}: 'assignmentFilters.{fk}' must be a non-empty string")

    if "win365" in data:
        w365 = data["win365"]
        if not isinstance(w365, dict):
            errs.append(f"{label}: 'win365' must be a JSON object")
        else:
            for req_w in ("provisioningPolicyIds", "userSettingsIds"):
                if req_w not in w365:
                    errs.append(f"{label}: missing required field 'win365.{req_w}'")
                elif not isinstance(w365[req_w], list) or not all(
                    isinstance(x, str) and x.strip() for x in w365[req_w]
                ):
                    errs.append(f"{label}: 'win365.{req_w}' must be an array of non-empty strings")

    return errs


def validate_cloud_environments_contract(data: Any, rel_path: Path) -> list[str]:
    """Validate contracts/cloud-environments.json (C26)."""
    errs: list[str] = []
    if not isinstance(data, dict):
        return [f"{rel_path}: contract root must be an object"]
    if data.get("schema") != "avd-cloud-environments/v1":
        errs.append(f"{rel_path}: 'schema' must equal 'avd-cloud-environments/v1'")
    clouds = data.get("clouds")
    if not isinstance(clouds, dict):
        errs.append(f"{rel_path}: 'clouds' must be an object")
        return errs
    for cloud_id, expected_graph in (
        ("commercial", "https://graph.microsoft.com"),
        ("usgov", "https://graph.microsoft.us"),
    ):
        c_obj = clouds.get(cloud_id)
        if not isinstance(c_obj, dict):
            errs.append(f"{rel_path}: missing clouds.{cloud_id}")
            continue
        if c_obj.get("graphEndpoint") != expected_graph:
            errs.append(
                f"{rel_path}: clouds.{cloud_id}.graphEndpoint must equal {expected_graph!r}"
            )
        caps = c_obj.get("capabilities")
        if not isinstance(caps, dict):
            errs.append(f"{rel_path}: clouds.{cloud_id}.capabilities must be an object")
    return errs


def validate_settings_catalog_profile(data: Any, rel_path: Path) -> list[str]:
    """Validate a Settings Catalog profile template."""
    errs: list[str] = []
    if not isinstance(data, dict):
        return [f"{rel_path}: profile root must be an object"]
    for req in ("name", "description", "platforms", "technologies", "settings"):
        if req not in data:
            errs.append(f"{rel_path}: missing required key '{req}'")
    if "name" in data and (not isinstance(data["name"], str) or not data["name"].startswith("[avd-ops]")):
        errs.append(f"{rel_path}: 'name' must be a string starting with '[avd-ops]'")
    if "complianceProfile" in data and data["complianceProfile"] not in ("standard", "itar-cui"):
        errs.append(
            f"{rel_path}: 'complianceProfile' must be one of standard, itar-cui"
        )
    if "settings" in data:
        if not isinstance(data["settings"], list) or not data["settings"]:
            errs.append(f"{rel_path}: 'settings' must be a non-empty list")
        else:
            for idx, item in enumerate(data["settings"]):
                if not isinstance(item, dict):
                    errs.append(f"{rel_path}: settings[{idx}] must be an object")
                elif "settingId" not in item and "settingInstance" not in item:
                    errs.append(
                        f"{rel_path}: settings[{idx}] must contain 'settingId' or 'settingInstance'"
                    )
    return errs


def validate_compliance_profile(data: Any, rel_path: Path) -> list[str]:
    """Validate a compliance policy template."""
    errs: list[str] = []
    if not isinstance(data, dict):
        return [f"{rel_path}: compliance profile root must be an object"]
    if data.get("@odata.type") != "#microsoft.graph.windows10CompliancePolicy":
        errs.append(
            f"{rel_path}: '@odata.type' must be '#microsoft.graph.windows10CompliancePolicy'"
        )
    display_name = data.get("displayName")
    if not isinstance(display_name, str) or not display_name.startswith("[avd-ops]"):
        errs.append(f"{rel_path}: 'displayName' must be a string starting with '[avd-ops]'")
    return errs


def validate_assignment_filter(data: Any, rel_path: Path) -> list[str]:
    """Validate a platform assignment filter template."""
    errs: list[str] = []
    if not isinstance(data, dict):
        return [f"{rel_path}: filter root must be an object"]
    for req in ("displayName", "description", "platform", "rule"):
        if req not in data:
            errs.append(f"{rel_path}: missing required key '{req}'")
    display_name = data.get("displayName")
    if not isinstance(display_name, str) or not display_name.startswith("[avd-ops]"):
        errs.append(f"{rel_path}: 'displayName' must be a string starting with '[avd-ops]'")
    if data.get("platform") != "windows10AndLater":
        errs.append(f"{rel_path}: 'platform' must be 'windows10AndLater'")
    rule = data.get("rule")
    if not isinstance(rule, str) or not rule.strip():
        errs.append(f"{rel_path}: 'rule' must be a non-empty string")
    return errs


def validate_win365_profile(data: Any, rel_path: Path) -> list[str]:
    """Validate a Windows 365 provisioning policy or user setting template."""
    errs: list[str] = []
    if not isinstance(data, dict):
        return [f"{rel_path}: Windows 365 profile root must be an object"]
    display_name = data.get("displayName")
    if not isinstance(display_name, str) or not display_name.startswith("[avd-ops]"):
        errs.append(f"{rel_path}: 'displayName' must be a string starting with '[avd-ops]'")
    if "enableSingleSignOn" in data and data.get("enableSingleSignOn") is not True:
        errs.append(f"{rel_path}: 'enableSingleSignOn' must be True on Windows 365 provisioning policies")
    if "localAdminEnabled" in data and data.get("localAdminEnabled") is not False:
        errs.append(f"{rel_path}: 'localAdminEnabled' must be False on Windows 365 user settings")
    return errs


def scan_text_for_leaks(text: str, label: str) -> list[str]:
    """Check text content for disallowed emails or leaked secret patterns."""
    errs: list[str] = []
    for match in EMAIL.finditer(text):
        addr = match.group(0)
        if not any(addr.endswith("@" + domain) for domain in ALLOWED_DOMAINS):
            errs.append(f"{label}: disallowed email address {addr}")
    for pat in SECRET_PATTERNS:
        if pat.search(text):
            errs.append(f"{label}: potential secret or private key pattern detected")
    return errs


def run_validation(manifest_path: Path | None = None) -> list[str]:
    """Run repository and optional manifest validation, returning any errors."""
    errors: list[str] = []

    schema_file = ROOT / "contracts" / "intune-manifest.schema.json"
    try:
        schema_data = json.loads(schema_file.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"contracts/intune-manifest.schema.json: failed to load schema: {exc}"]

    c26_file = ROOT / "contracts" / "cloud-environments.json"
    if not c26_file.is_file():
        errors.append("contracts/cloud-environments.json: missing C26 cloud environments contract")
    else:
        try:
            c26_data = json.loads(c26_file.read_text(encoding="utf-8"))
            errors.extend(validate_cloud_environments_contract(c26_data, c26_file.relative_to(ROOT)))
        except Exception as exc:
            errors.append(f"contracts/cloud-environments.json: invalid JSON: {exc}")

    for jf in sorted(ROOT.rglob("*.json")):
        if ".git" in jf.parts:
            continue
        rel = jf.relative_to(ROOT)
        try:
            data = json.loads(jf.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"{rel}: invalid JSON: {exc}")
            continue
        if not isinstance(data, (dict, list)):
            errors.append(f"{rel}: root must be object or array")
            continue

        if jf.parent == ROOT / "profiles" / "settings-catalog":
            errors.extend(validate_settings_catalog_profile(data, rel))
        elif jf.parent == ROOT / "profiles" / "compliance":
            errors.extend(validate_compliance_profile(data, rel))
        elif jf.parent == ROOT / "profiles" / "filters":
            errors.extend(validate_assignment_filter(data, rel))
        elif jf.parent == ROOT / "profiles" / "win365":
            errors.extend(validate_win365_profile(data, rel))

    for tf in sorted(ROOT.rglob("*")):
        if ".git" in tf.parts or "__pycache__" in tf.parts or not tf.is_file():
            continue
        try:
            text = tf.read_text(encoding="utf-8")
        except Exception:
            continue
        errors.extend(scan_text_for_leaks(text, str(tf.relative_to(ROOT))))

    if manifest_path is not None:
        resolved = manifest_path.resolve()
        label = str(manifest_path)
        if not resolved.is_file():
            errors.append(f"{label}: manifest file does not exist")
        else:
            try:
                raw_manifest = resolved.read_text(encoding="utf-8")
                manifest_data = json.loads(raw_manifest)
            except Exception as exc:
                errors.append(f"{label}: invalid JSON: {exc}")
            else:
                errors.extend(validate_intune_manifest(manifest_data, label, schema_data))
                errors.extend(scan_text_for_leaks(raw_manifest, label))

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate avd-intune JSON templates, schemas, and no-leak rules."
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="Optional path to an emitted intune-manifest.json to validate against the contract schema.",
    )
    args = parser.parse_args(argv)

    errors = run_validation(manifest_path=args.manifest)
    if errors:
        for err in errors:
            print(f"::error::{err}")
        return 1

    print("All JSON templates, schemas, and leak checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
