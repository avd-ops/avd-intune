#!/usr/bin/env python3
"""Validate all JSON templates, contract schemas, and no-leak guardrails in this repository."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
ALLOWED_DOMAINS = ("example.com", "contoso.com", "users.noreply.github.com")

errors: list[str] = []

for jf in ROOT.rglob("*.json"):
    if ".git" in jf.parts:
        continue
    try:
        data = json.loads(jf.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{jf.relative_to(ROOT)}: invalid JSON: {exc}")
        continue
    if not isinstance(data, (dict, list)):
        errors.append(f"{jf.relative_to(ROOT)}: root must be object or array")

for tf in ROOT.rglob("*"):
    if ".git" in tf.parts or not tf.is_file():
        continue
    try:
        text = tf.read_text(encoding="utf-8")
    except Exception:
        continue
    for m in EMAIL.finditer(text):
        addr = m.group(0)
        if not any(addr.endswith("@" + d) for d in ALLOWED_DOMAINS):
            errors.append(f"{tf.relative_to(ROOT)}: disallowed email address {addr}")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)

print("All JSON templates, schemas, and leak checks passed.")
