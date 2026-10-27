#!/usr/bin/env bash
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
set -euo pipefail

ENTRA_MANIFEST="${1:-entra-manifest.json}"
OUT_FILE="${2:-intune-manifest.json}"

python3 scripts/validate.py
echo "Validated Intune Settings Catalog and Compliance baselines (input: ${ENTRA_MANIFEST}, output: ${OUT_FILE})."
