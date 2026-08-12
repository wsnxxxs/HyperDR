#!/usr/bin/env python3
"""Apply the registered rule for the path where Core Image does the upsampling.

`validate_t2.py` judges the harness-resampled path, which cannot answer the
question T2 was registered to settle: this harness interpolates the codes and
Core Image only decodes them, so the order is fixed before Apple sees anything.
The `core_image_upsampled_gain` records hand Core Image the native-resolution
gain map instead, and this script applies the rule registered for them in
`fixture_spec.json` under `core_image_upsampled_gain_acceptance`.

It decides nothing that was not written down before the data existed, and it is
not a substitute for the frozen validator. Run it on the evidence bundle.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys


def errors(actual: list[float], expected: list[float]) -> dict:
    if len(actual) != len(expected) or not actual:
        raise ValueError("pixel arrays have different or empty lengths")
    absolute = [abs(float(a) - float(b)) for a, b in zip(actual, expected)]
    if not all(math.isfinite(v) for v in absolute):
        raise ValueError("comparison produced a non-finite error")
    return {
        "mean_absolute_error": sum(absolute) / len(absolute),
        "max_absolute_error": max(absolute),
        "samples": len(absolute),
    }


def clears(err: dict, rule: dict) -> bool:
    return (err["mean_absolute_error"] <= rule["code_domain_mean_absolute_error_max"]
            and err["max_absolute_error"] <= rule["code_domain_max_absolute_error_max"])


def separated(near: dict, far: dict, rule: dict) -> bool:
    return (far["mean_absolute_error"] >= rule["alternative_mean_absolute_error_min"]
            and near["mean_absolute_error"]
            <= rule["code_to_alternative_mae_ratio_max"] * far["mean_absolute_error"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", type=pathlib.Path, required=True)
    parser.add_argument("--core-image", type=pathlib.Path, required=True)
    parser.add_argument("--cpp", type=pathlib.Path, action="append", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    arguments = parser.parse_args()

    spec = json.loads(arguments.spec.read_text(encoding="utf-8"))
    rule = spec["core_image_upsampled_gain_acceptance"]
    core = json.loads(arguments.core_image.read_text(encoding="utf-8"))
    cpp = {}
    for path in arguments.cpp:
        record = json.loads(path.read_text(encoding="utf-8"))
        cpp[record["fixture_id"]] = record

    fixtures, notes = [], []
    for record in core.get("fixtures", []):
        fixture_id = record["id"]
        reference = cpp.get(fixture_id)
        if reference is None:
            notes.append(f"no C++ hypotheses for {fixture_id}")
            continue
        by_headroom = {float(n["physical_headroom_stops"]): n for n in reference["nodes"]}
        nodes = []
        for node in record["nodes"]:
            stops = float(node["physical_headroom_stops"])
            native = node.get("core_image_upsampled_gain", {})
            if not native.get("available"):
                nodes.append({"physical_headroom_stops": stops,
                              "available": False,
                              "reason": native.get("reason", "not recorded")})
                continue
            hypotheses = by_headroom[stops]
            code = errors(native["rgb"], hypotheses["code_domain_rgb"])
            decoded = errors(native["rgb"], hypotheses["decoded_domain_first_rgb"])
            nodes.append({
                "physical_headroom_stops": stops,
                "available": True,
                "code_domain_error": code,
                "decoded_domain_first_error": decoded,
                "code_domain_clears": clears(code, rule) and separated(code, decoded, rule),
                "decoded_domain_clears": clears(decoded, rule) and separated(decoded, code, rule),
            })
        usable = [n for n in nodes if n.get("available")]
        complete = usable and len(usable) == len(nodes)
        if not usable:
            verdict = "unavailable"
        elif record.get("gamma") == 1.0:
            # The two orders are the same function at gamma = 1, so this fixture
            # cannot separate them and must not be scored as if it could. What it
            # can say is whether the path reproduces the reconstruction at all.
            verdict = "consistent" if complete and all(
                clears(n["code_domain_error"], rule) for n in usable) else "inconsistent"
        elif complete and all(n["code_domain_clears"] for n in usable):
            verdict = "code_domain"
        elif complete and all(n["decoded_domain_clears"] for n in usable):
            verdict = "decoded_domain"
        else:
            verdict = "unresolved"
        fixtures.append({"id": fixture_id, "gamma": record.get("gamma"),
                         "verdict": verdict, "nodes": nodes})

    gamma_one = [f for f in fixtures if f.get("gamma") == 1.0]
    probe = [f for f in fixtures if f.get("gamma") != 1.0]
    # At gamma = 1 the two orders coincide, so that fixture carries no
    # information about the order and only shows whether the path works at all.
    verdict = probe[0]["verdict"] if len(probe) == 1 else "unresolved"
    report = {
        "schema_version": 1,
        "analysis": "core_image_upsampled_gain",
        "registered_rule": rule,
        "verdict": verdict,
        "verdict_scope": "Applies to the probe fixture only; the gamma=1 control cannot separate the orders.",
        "control_fixture_verdicts": [f["verdict"] for f in gamma_one],
        "fixtures": fixtures,
        "notes": notes,
    }
    arguments.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"verdict": verdict,
                      "control": [f["verdict"] for f in gamma_one],
                      "notes": notes}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
