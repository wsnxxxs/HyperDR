"""Regenerate only when intentionally updating the frozen Python contract.

Run from the repository root: python3 tests/capi/golden/generate.py.
Normal tests consume edit_options.json and do not import the Python panel.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "apps/panel"))
from hyperdr_panel.command import build_argv, options_to_settings

TARGET = Path(__file__).with_name("edit_options.json")
# Retain the pre-implementation cases; add each schema boundary independently.
rows = json.loads(TARGET.read_text())
options = [row["options"] for row in rows]
settings = json.loads((ROOT / "schema/settings.json").read_text())["settings"]
if isinstance(settings, list):
    settings = {entry["key"]: entry for entry in settings}
for panel, key in {"contrast": "contrast", "vibrance": "vibrance",
                   "hdrStrength": "gain_strength", "hdrRange": "headroom",
                   "brightness": "exposure_bias", "expansionStart": "expansion_start",
                   "areaCoverage": "area_coverage", "quality": "quality",
                   "lutStrength": "lut_strength"}.items():
    entry = settings[key]
    for boundary in (entry.get("minimum"), entry.get("maximum")):
        if boundary is not None:
            option = {"input": "/fixtures/source.jpg", "output": "/exports",
                      "report": "/exports/report.json", panel: boundary}
            if option not in options:
                options.append(option)
options.append({"input": "/fixtures/source.jpg", "output": "/exports", "report": "/exports/report.json",
                "colorGamut": "p3", "_raw_profile_path": "/profile.dcp", "_raw_look_path": "/look.dcp",
                "_lens_profile_path": "/lens.lcp", "_lut_path": "/look.cube", "lutInput": "p3",
                "lutOutput": "srgb", "lutStrength": .333333})
unique = []
for option in options:
    if option not in unique:
        unique.append(option)
rows = []
for option in unique:
    row = {"options": option}
    try:
        row["settings"] = options_to_settings(option)
        row["argv"] = build_argv("HyperDR", option)
    except ValueError as error:
        row["error"] = str(error)
    rows.append(row)
TARGET.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
print(f"Wrote {len(rows)} Python contract cases")
