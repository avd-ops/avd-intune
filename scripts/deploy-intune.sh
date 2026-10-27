#!/usr/bin/env bash
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
set -euo pipefail

ENTRA_MANIFEST="${1:-./entra-manifest.json}"
OUT_FILE="${2:-./intune-manifest.json}"
RUN_MANIFEST="${3:-./intune-run-manifest.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 "${REPO_ROOT}/scripts/validate.py"

pwsh -NoProfile -File "${REPO_ROOT}/scripts/Deploy-AvdIntune.ps1" \
  -EntraManifestPath "${ENTRA_MANIFEST}" \
  -OutputPath "${OUT_FILE}" \
  -RunManifestPath "${RUN_MANIFEST}"

python3 "${REPO_ROOT}/scripts/validate.py" --manifest "${OUT_FILE}"
echo "Deployed and validated Intune Settings Catalog and Compliance baselines (input: ${ENTRA_MANIFEST}, output: ${OUT_FILE})."
