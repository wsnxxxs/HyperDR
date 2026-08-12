#!/usr/bin/env python3
"""Validate Core Image against the checked-in C++ reconstruction source."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import struct
import sys


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha256_source(path: pathlib.Path) -> str:
    """Identify a text source by content, with line endings normalised to LF.

    Matches generate_fixtures.sha256_source. `* text=auto` gives the C++ sources
    CRLF in a Windows checkout and LF in a macOS one, so a plain byte hash would
    reject the same source purely for running this gate on macOS."""
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def read_bundle(path: pathlib.Path) -> dict:
    blob = path.read_bytes()
    if blob[:8] != b"HDT2IN01" or len(blob) < 24:
        raise ValueError(f"invalid decoded input bundle: {path}")
    base_width, base_height, gain_width, gain_height = struct.unpack_from("<IIII", blob, 8)
    base_count = base_width * base_height * 3
    gain_count = gain_width * gain_height
    expected = 24 + (base_count + gain_count) * 4
    if len(blob) != expected:
        raise ValueError(f"decoded input bundle length mismatch: {path}")
    values = struct.unpack_from("<" + "f" * (base_count + gain_count), blob, 24)
    if not all(math.isfinite(value) for value in values):
        raise ValueError(f"non-finite decoded input bundle: {path}")
    return {
        "base_width": base_width,
        "base_height": base_height,
        "gain_width": gain_width,
        "gain_height": gain_height,
        "base": values[:base_count],
        "gain": values[base_count:],
    }


def errors(actual: list[float], expected: list[float]) -> dict:
    if len(actual) != len(expected) or not actual:
        raise ValueError("pixel arrays have different or empty lengths")
    absolute = [abs(float(left) - float(right)) for left, right in zip(actual, expected)]
    if not all(math.isfinite(value) for value in absolute):
        raise ValueError("pixel comparison produced a non-finite error")
    return {
        "mean_absolute_error": sum(absolute) / len(absolute),
        "max_absolute_error": max(absolute),
        "compared_channel_samples": len(absolute),
    }


def verify_fixture_pair(spec: dict, manifest: dict, manifest_path: pathlib.Path) -> bool:
    records = {record["id"]: record for record in manifest.get("fixtures", [])}
    blobs = {}
    for fixture in spec["fixtures"]:
        record = records.get(fixture["id"])
        if record is None or record.get("path") != fixture["filename"]:
            return False
        path = manifest_path.parent / record["path"]
        if (not path.is_file() or path.stat().st_size != record.get("byte_length")
                or sha256(path) != record.get("sha256")):
            return False
        blobs[fixture["id"]] = path.read_bytes()
    if set(blobs) != {"gamma-1-control", "gamma-2-probe"}:
        return False
    control = blobs["gamma-1-control"]
    probe = blobs["gamma-2-probe"]
    differences = [index for index, pair in enumerate(zip(control, probe)) if pair[0] != pair[1]]
    invariant = manifest.get("pair_invariant", {})
    return (
        len(control) == len(probe)
        and differences == invariant.get("differing_absolute_offsets")
        and len(differences) == invariant.get("differing_byte_count") == 1
        and control[differences[0]] == int(invariant.get("control_byte_hex", ""), 16)
        and probe[differences[0]] == int(invariant.get("probe_byte_hex", ""), 16)
        and differences[0]
        == invariant.get("tmap_payload_absolute_offset")
        + invariant.get("gamma_numerator_last_byte_offset_within_payload")
    )


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def validate_schema(value, schema: dict, location: str = "$") -> list[str]:
    """Validate the small JSON-Schema subset used by the frozen T2 schema."""
    problems: list[str] = []
    if "const" in schema and value != schema["const"]:
        problems.append(f"{location}: value does not match const")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{location}: value is not in enum")
    expected_type = schema.get("type")
    type_ok = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
    }.get(expected_type, True)
    if not type_ok:
        return problems + [f"{location}: expected {expected_type}"]
    if expected_type == "string" and len(value) < schema.get("minLength", 0):
        problems.append(f"{location}: string is too short")
    if expected_type == "array":
        if len(value) < schema.get("minItems", 0):
            problems.append(f"{location}: array has too few items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            problems.append(f"{location}: array has too many items")
        if isinstance(schema.get("items"), dict):
            for index, item in enumerate(value):
                problems.extend(validate_schema(item, schema["items"], f"{location}[{index}]"))
    if expected_type == "object":
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                problems.append(f"{location}: missing required key {key}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    problems.append(f"{location}: unexpected key {key}")
        for key, child_schema in properties.items():
            if key in value:
                problems.extend(validate_schema(value[key], child_schema, f"{location}.{key}"))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--core-image", type=pathlib.Path, required=True)
    parser.add_argument("--cpp", type=pathlib.Path, action="append", required=True)
    parser.add_argument("--schema", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    arguments = parser.parse_args()

    spec = json.loads(arguments.spec.read_text(encoding="utf-8"))
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    core = json.loads(arguments.core_image.read_text(encoding="utf-8"))
    cpp_reports = {
        report["fixture_id"]: report
        for report in (
            json.loads(path.read_text(encoding="utf-8")) for path in arguments.cpp
        )
    }
    schema = json.loads(arguments.schema.read_text(encoding="utf-8"))
    failures: list[str] = []
    require(schema.get("$id") == "https://hyperdr.local/schema/macos-display-t2-report-v1.json",
            "unexpected report schema identity", failures)
    require(core.get("protocol_id") == spec["protocol_id"] == manifest["protocol_id"],
            "protocol identities disagree", failures)
    fixture_pair_valid = verify_fixture_pair(spec, manifest, arguments.manifest)
    require(fixture_pair_valid, "fixture identity or only-gamma invariant failed", failures)
    reconstruct_path = arguments.spec.parents[2] / "modules/gainmap/src/reconstruct.cpp"
    require(
        manifest.get("source_sha256", {}).get("modules/gainmap/src/reconstruct.cpp")
        == sha256_source(reconstruct_path),
        "C++ reconstruction source does not match the fixture provenance",
        failures,
    )
    headrooms = [float(value) for value in spec["physical_headroom_stops"]]
    require(3 <= len(headrooms) <= 5 and 0 < headrooms[0] < headrooms[-1] < 2
            and all(left < right for left, right in zip(headrooms, headrooms[1:])),
            "headrooms are not three to five ordered interior physical-H nodes", failures)
    core_fixtures = {item["id"]: item for item in core.get("fixtures", [])}
    expected_ids = [item["id"] for item in spec["fixtures"]]
    require(set(core_fixtures) == set(expected_ids), "Core Image fixture set mismatch", failures)
    require(set(cpp_reports) == set(expected_ids), "C++ fixture set mismatch", failures)

    output_root = arguments.core_image.parent
    bundles = {}
    for fixture_id in expected_ids:
        if fixture_id not in core_fixtures:
            continue
        record = core_fixtures[fixture_id]
        bundle = read_bundle(output_root / record["decoded_input_bundle"])
        bundles[fixture_id] = bundle
        require(record.get("imageio_iso_gain_map_present") is True,
                f"ImageIO did not expose ISO gain map: {fixture_id}", failures)
        require(record.get("gain_properties_present") is True,
                f"Core Image gain properties missing: {fixture_id}", failures)
        require(record.get("imageio_source_count") == 1,
                f"unexpected ImageIO primary image count: {fixture_id}", failures)
        require(bundle["base_width"] == record["base_width"] and
                bundle["base_height"] == record["base_height"] and
                bundle["gain_width"] == record["gain_width"] and
                bundle["gain_height"] == record["gain_height"],
                f"decoded dimensions disagree: {fixture_id}", failures)
        require(bundle["base_width"] > bundle["gain_width"] and
                bundle["base_height"] > bundle["gain_height"],
                f"fixture does not exercise two-axis upsampling: {fixture_id}", failures)
        require(
            [bundle["base_width"], bundle["base_height"]]
            == [spec["base"]["width"], spec["base"]["height"]]
            and [bundle["gain_width"], bundle["gain_height"]]
            == [spec["gain"]["width"], spec["gain"]["height"]],
            f"decoded dimensions differ from the frozen fixture spec: {fixture_id}",
            failures,
        )
        require(min(bundle["gain"]) >= -1e-6 and max(bundle["gain"]) <= 1.0 + 1e-6,
                f"decoded gain codes are outside [0,1]: {fixture_id}", failures)
        require(min(bundle["gain"]) <= 0.01 and max(bundle["gain"]) >= 0.99,
                f"decoded gain probe lost its endpoint codes: {fixture_id}", failures)
    if set(bundles) == set(expected_ids):
        require(bundles["gamma-1-control"]["base"] == bundles["gamma-2-probe"]["base"],
                "decoded SDR bases differ despite the only-gamma file invariant", failures)
        require(bundles["gamma-1-control"]["gain"] == bundles["gamma-2-probe"]["gain"],
                "decoded gain codes differ despite the only-gamma file invariant", failures)

    thresholds = spec["acceptance"]
    fixture_results = []
    headroom_conversion_valid = True
    for fixture_id in expected_ids:
        if fixture_id not in core_fixtures or fixture_id not in cpp_reports:
            continue
        core_record = core_fixtures[fixture_id]
        cpp_record = cpp_reports[fixture_id]
        spec_record = next(item for item in spec["fixtures"] if item["id"] == fixture_id)
        expected_gamma = (
            spec_record["gamma"]["numerator"] / spec_record["gamma"]["denominator"]
        )
        require(abs(float(core_record.get("gamma", math.nan)) - expected_gamma) <= 1e-12,
                f"Core Image gamma identity mismatch: {fixture_id}", failures)
        require(abs(float(cpp_record.get("gamma", math.nan)) - expected_gamma) <= 1e-12,
                f"C++ gamma identity mismatch: {fixture_id}", failures)
        require(
            cpp_record.get("implementation")
            == "modules/gainmap/src/reconstruct.cpp::reconstruct_gain_map",
            f"unexpected C++ implementation identity: {fixture_id}",
            failures,
        )
        cpp_nodes = {
            float(node["physical_headroom_stops"]): node for node in cpp_record["nodes"]
        }
        core_node_values = [float(node["physical_headroom_stops"]) for node in core_record["nodes"]]
        require(core_node_values == headrooms,
                f"Core Image headroom node set/order mismatch: {fixture_id}", failures)
        require(sorted(cpp_nodes) == headrooms,
                f"C++ headroom node set mismatch: {fixture_id}", failures)
        node_results = []
        for core_node in core_record["nodes"]:
            stops = float(core_node["physical_headroom_stops"])
            require(stops in cpp_nodes, f"C++ node missing at H={stops}: {fixture_id}", failures)
            if stops not in cpp_nodes:
                continue
            expected_linear = 2.0**stops
            passed_linear = float(core_node["linear_headroom_passed_to_core_image"])
            node_headroom_valid = abs(passed_linear - expected_linear) <= 2e-6
            headroom_conversion_valid = headroom_conversion_valid and node_headroom_valid
            require(node_headroom_valid,
                    f"Core Image headroom was not 2^H: {fixture_id} H={stops}", failures)
            cpp_node = cpp_nodes[stops]
            code_error = errors(core_node["rgb"], cpp_node["code_domain_rgb"])
            alternative_error = errors(
                core_node["rgb"], cpp_node["decoded_domain_first_rgb"]
            )
            code_pass = (
                code_error["mean_absolute_error"]
                <= thresholds["code_domain_mean_absolute_error_max"]
                and code_error["max_absolute_error"]
                <= thresholds["code_domain_max_absolute_error_max"]
            )
            require(code_pass, f"Core Image/C++ pixel gate failed: {fixture_id} H={stops}", failures)
            if fixture_id == "gamma-2-probe":
                alternative_separated = (
                    alternative_error["mean_absolute_error"]
                    >= thresholds["probe_alternative_mean_absolute_error_min"]
                    and code_error["mean_absolute_error"]
                    <= thresholds["probe_code_to_alternative_mae_ratio_max"]
                    * alternative_error["mean_absolute_error"]
                )
                require(alternative_separated,
                        f"gamma=2 probe did not distinguish interpolation order at H={stops}",
                        failures)
            else:
                alternative_separated = None
                require(
                    errors(cpp_node["code_domain_rgb"], cpp_node["decoded_domain_first_rgb"])[
                        "max_absolute_error"
                    ] <= 1e-7,
                    f"gamma=1 control candidates are not identical at H={stops}",
                    failures,
                )
            node_results.append({
                "physical_headroom_stops": stops,
                "linear_headroom_passed_to_core_image": passed_linear,
                "code_domain_error": code_error,
                "decoded_domain_first_error": alternative_error,
                "code_domain_pixel_gate_pass": code_pass,
                "alternative_separated": alternative_separated,
            })
        fixture_results.append({
            "id": fixture_id,
            "gamma": core_record["gamma"],
            "base_size": [core_record["base_width"], core_record["base_height"]],
            "gain_size": [core_record["gain_width"], core_record["gain_height"]],
            "nodes": node_results,
        })

    report = {
        "schema_version": 1,
        "protocol_id": spec["protocol_id"],
        "gate": "T2",
        "status": "pass" if not failures else "fail",
        "decision": (
            "macOS Core Image is pixelwise consistent with code-domain interpolation "
            "before inverse gamma at all registered physical headrooms"
            if not failures
            else "T2 remains unresolved because one or more frozen gates failed"
        ),
        "platform": core.get("platform"),
        "renderer": core.get("renderer"),
        "renderer_configuration": core.get("renderer_configuration"),
        "provenance": {
            "fixture_manifest_sha256": sha256(arguments.manifest),
            "fixture_spec_sha256": sha256(arguments.spec),
            "cpp_reconstruct_source": "modules/gainmap/src/reconstruct.cpp",
            "protocol_registration_sha256": spec["protocol_registration"]["sha256"],
            "cpp_reconstruct_source_sha256": sha256_source(reconstruct_path),
            "source_sha256_line_ending_normalisation": "CRLF sequences are replaced by LF before hashing text sources",
            "core_image_harness_sha256": sha256(
                arguments.spec.parent / "CoreImageT2.swift"
            ),
            "cpp_reference_harness_sha256": sha256(
                arguments.spec.parent / "cpp_reference.cpp"
            ),
            "validator_sha256": sha256(pathlib.Path(__file__).resolve()),
            "core_image_intermediate_report_sha256": sha256(arguments.core_image),
            "cpp_intermediate_report_sha256": {
                path.name: sha256(path) for path in arguments.cpp
            },
            "decoded_input_bundle_sha256": {
                fixture_id: sha256(
                    output_root / core_fixtures[fixture_id]["decoded_input_bundle"]
                )
                for fixture_id in expected_ids
                if fixture_id in core_fixtures
            },
            "report_schema_sha256": sha256(arguments.schema),
        },
        "invariants": {
            "fixture_pair_differs_only_in_gamma": fixture_pair_valid,
            "decoded_base_pixels_identical_across_pair": (
                set(bundles) == set(expected_ids)
                and bundles["gamma-1-control"]["base"] == bundles["gamma-2-probe"]["base"]
            ),
            "decoded_gain_pixels_identical_across_pair": (
                set(bundles) == set(expected_ids)
                and bundles["gamma-1-control"]["gain"] == bundles["gamma-2-probe"]["gain"]
            ),
            "physical_headroom_nodes_distinct": len(set(headrooms)) == len(headrooms),
            "core_image_received_linear_two_to_the_H": headroom_conversion_valid,
        },
        "thresholds": thresholds,
        "fixtures": fixture_results,
        "failures": failures,
    }
    schema_problems = validate_schema(report, schema)
    if schema_problems:
        raise ValueError("generated T2 report violates its schema: " + "; ".join(schema_problems))
    arguments.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "failures": failures}, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
