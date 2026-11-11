#!/usr/bin/env bash
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
set -euo pipefail

ENTRA_MANIFEST="${1:-./entra-manifest.json}"
OUT_FILE="${2:-./intune-manifest.json}"
RUN_MANIFEST="${3:-./intune-run-manifest.json}"
CLOUD="${4:-${AVD_CLOUD:-commercial}}"
COMPLIANCE_PROFILE="${5:-${AVD_COMPLIANCE_PROFILE:-}}"

if [[ -z "${COMPLIANCE_PROFILE}" ]]; then
  if [[ "${CLOUD}" == "usgov" ]]; then
    COMPLIANCE_PROFILE="itar-cui"
  else
    COMPLIANCE_PROFILE="standard"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 "${REPO_ROOT}/scripts/validate.py"

pwsh -NoProfile -File "${REPO_ROOT}/scripts/Deploy-AvdIntune.ps1" \
  -EntraManifestPath "${ENTRA_MANIFEST}" \
  -OutputPath "${OUT_FILE}" \
  -RunManifestPath "${RUN_MANIFEST}" \
  -Cloud "${CLOUD}" \
  -ComplianceProfile "${COMPLIANCE_PROFILE}"

python3 "${REPO_ROOT}/scripts/validate.py" --manifest "${OUT_FILE}"
echo "Deployed and validated Intune Settings Catalog and Compliance baselines (cloud: ${CLOUD}, complianceProfile: ${COMPLIANCE_PROFILE}, input: ${ENTRA_MANIFEST}, output: ${OUT_FILE})."
