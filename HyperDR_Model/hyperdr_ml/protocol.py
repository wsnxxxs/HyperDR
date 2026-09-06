"""Frozen direct-calibration protocol helpers.

This module contains the data-bound parts of the Apple direct signed-gain
protocol.  Construction records only the test hash frozen in the development
fold manifest; it never parses test membership.  Test IDs become readable only
after an exclusive dataset-wide one-shot ledger claim, while development fold
helpers can return only the five development folds.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Iterable, Mapping, Sequence

import numpy as np


PROTOCOL_ID = "hyperdr.direct-calibration/v2"
DEFAULT_SPLIT_MANIFEST = "splits/cv-folds-v1.json"
DEFAULT_TEST_SPLIT = "splits/test.json"
DEFAULT_DOMAIN = "iso_native"
CALIBRATION_EPSILON = 1e-6
BOOTSTRAP_RESAMPLES = 10_000
SELF_DERIVED_ARM = "self_derived"
M_PRESERVING_AFFINE_STRETCH_DIAGNOSTIC_ARM = (
    "m_preserving_affine_stretch_diagnostic"
)
G_PRESERVING_METADATA_ENVELOPE_ARM = "g_preserving_metadata_envelope"
OUTWARD_MEDIAN_ENVELOPE_METHOD = (
    "capture_group_equal_outward_median_metadata_envelope"
)
TEST_LEDGER_SCHEMA = "hyperdr.test-split-consumption/v1"
_SAMPLE_ID_FIELD = re.compile(
    r'"sample_id"\s*:\s*(?P<value>"(?:[^"\\]|\\.)*")'
)


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def _rational_value(value: object) -> float:
    if isinstance(value, Mapping):
        numerator = float(value["numerator"])
        denominator = float(value["denominator"])
        if denominator == 0.0:
            raise ValueError(f"invalid zero-denominator rational: {value}")
        return numerator / denominator
    return float(value)


def _finite(value: float, name: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"non-finite {name}: {value!r}")
    return value


@dataclass(frozen=True)
class EndpointTarget:
    gain_min: float
    gain_max: float


@dataclass(frozen=True)
class AffineMap:
    feature: str
    slope: float
    intercept: float
    rows: int

    def apply(self, value: float) -> float:
        result = self.slope * value + self.intercept
        return _finite(result, f"calibrated {self.feature}")


@dataclass(frozen=True)
class EndpointArmEncoding:
    """Numerical representation of one endpoint-delivery arm.

    ``canonical_gain`` is the gain that the candidate file is intended to
    decode to at full weight.  ``encoded_m`` is the normalized value written
    under ``gain_min``/``gain_max`` before writer gamma is applied.  Keeping
    both arrays visible prevents an endpoint operation that changes G from
    being mislabeled as metadata-only calibration.
    """

    arm: str
    canonical_gain: np.ndarray
    encoded_m: np.ndarray
    gain_min: float
    gain_max: float
    raw_min: float
    raw_max: float
    max_abs_reconstruction_error: float


class InvalidMetadataEnvelope(ValueError):
    """A selected metadata interval cannot encode the predicted G unchanged."""

    def __init__(
        self,
        *,
        raw_min: float,
        raw_max: float,
        envelope_min: float,
        envelope_max: float,
    ) -> None:
        self.raw_min = raw_min
        self.raw_max = raw_max
        self.envelope_min = envelope_min
        self.envelope_max = envelope_max
        super().__init__(
            "metadata envelope does not contain predicted G: "
            f"[{envelope_min}, {envelope_max}] does not contain "
            f"[{raw_min}, {raw_max}]"
        )


@dataclass(frozen=True)
class OneShotTestV2Claim:
    """Capability returned only after the dataset-wide ledger is claimed."""

    ledger_path: Path
    protocol_id: str
    test_split_sha256: str
    entrypoint: str
    artifact_kind: str
    artifact_sha256: str


class AppleProtocolCorpus:
    """Hash-locked view whose constructor exposes development data only.

    Test membership and its associated manifest rows, labels, and group
    assignments are materialized only by :meth:`ids_for_test_v2`, after the
    caller has spent the dataset-wide one-shot capability.
    """

    def __init__(
        self,
        root: str | Path,
        split_manifest: str | Path = DEFAULT_SPLIT_MANIFEST,
        test_split: str | Path = DEFAULT_TEST_SPLIT,
    ) -> None:
        self.root = Path(root)
        self.split_manifest_path = self.root / split_manifest
        self.test_split_path = self.root / test_split
        self.groups_path = self.root / "splits" / "groups.json"
        self.samples_manifest_path = self.root / "manifests" / "samples.jsonl"
        self.phase_label_dir = self.root / "manifests" / "phase_a_labels_v2"
        if not self.split_manifest_path.exists():
            raise FileNotFoundError(self.split_manifest_path)

        split_payload = _read_json(self.split_manifest_path)
        if not isinstance(split_payload, Mapping):
            raise ValueError(f"invalid split manifest: {self.split_manifest_path}")
        if int(split_payload.get("fold_count", 0)) != 5:
            raise ValueError("direct-calibration-v2 requires exactly five folds")
        self.split_payload = split_payload
        source_sha256 = split_payload.get("source_sha256")
        if not isinstance(source_sha256, Mapping):
            raise ValueError("split manifest lacks frozen source_sha256 records")
        self.test_split_sha256 = str(source_sha256.get("test.json", "")).lower()
        if len(self.test_split_sha256) != 64 or any(
            character not in "0123456789abcdef"
            for character in self.test_split_sha256
        ):
            raise ValueError("split manifest has no valid frozen test.json SHA-256")
        self.sample_fold: dict[str, int] = {
            str(sample_id): int(fold)
            for sample_id, fold in dict(split_payload.get("sample_fold", {})).items()
        }
        if not self.sample_fold:
            raise ValueError("split manifest has no sample_fold assignments")

        development_ids = set(self.sample_fold)
        self.groups, self.group_by_sample = self._load_groups(development_ids)
        self.manifest = self._load_manifest_rows(development_ids)
        self.phase_labels = self._load_phase_labels(development_ids)
        self._validate()

    def _load_groups(
        self,
        sample_ids: Iterable[str],
    ) -> tuple[list[dict[str, object]], dict[str, str]]:
        """Return capture-group data restricted to ``sample_ids``."""
        requested = {str(sample_id) for sample_id in sample_ids}
        groups_payload = _read_json(self.groups_path)
        if not isinstance(groups_payload, Mapping):
            raise ValueError("invalid capture-group manifest")
        raw_groups = groups_payload.get("groups")
        if not isinstance(raw_groups, list) or not raw_groups:
            raise ValueError("capture-group manifest is empty")

        groups: list[dict[str, object]] = []
        group_by_sample: dict[str, str] = {}
        for raw_group in raw_groups:
            if not isinstance(raw_group, Mapping):
                continue
            group = dict(raw_group)
            raw_members = group.get("members")
            if not isinstance(raw_members, list):
                continue
            members = [str(item) for item in raw_members]
            selected_members = [item for item in members if item in requested]
            if not selected_members:
                continue
            group_id = str(group.get("group_id", ""))
            if not group_id:
                raise ValueError(f"invalid capture group for requested samples: {group}")
            groups.append({"group_id": group_id, "members": selected_members})
            for sample_id in selected_members:
                if sample_id in group_by_sample:
                    raise ValueError(f"sample appears in multiple capture groups: {sample_id}")
                group_by_sample[sample_id] = group_id
        return groups, group_by_sample

    def _load_manifest_rows(
        self,
        sample_ids: Iterable[str],
    ) -> dict[str, dict[str, object]]:
        """Load and retain only requested sample-manifest rows."""
        requested = {str(sample_id) for sample_id in sample_ids}
        rows: dict[str, dict[str, object]] = {}
        with self.samples_manifest_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                sample_id_match = _SAMPLE_ID_FIELD.search(line)
                if sample_id_match is None:
                    continue
                sample_id = str(json.loads(sample_id_match.group("value")))
                if sample_id not in requested:
                    continue
                payload = json.loads(line)
                if not isinstance(payload, Mapping) or "sample_id" not in payload:
                    raise ValueError(f"invalid sample manifest row: {payload}")
                if str(payload["sample_id"]) != sample_id:
                    raise ValueError(f"invalid sample manifest row: {payload}")
                if sample_id in rows:
                    raise ValueError(f"duplicate sample manifest row: {sample_id}")
                rows[sample_id] = dict(payload)
                if rows.keys() == requested:
                    break
        return rows

    def _load_phase_labels(
        self,
        sample_ids: Iterable[str],
    ) -> dict[str, dict[str, object]]:
        """Read label files for requested IDs without enumerating the directory."""
        labels: dict[str, dict[str, object]] = {}
        for sample_id in sorted({str(item) for item in sample_ids}):
            if not sample_id or Path(sample_id).name != sample_id:
                raise ValueError(f"invalid sample ID for phase-label lookup: {sample_id!r}")
            path = self.phase_label_dir / f"{sample_id}.json"
            if not path.exists():
                continue
            payload = _read_json(path)
            if not isinstance(payload, Mapping):
                raise ValueError(f"invalid phase label: {path}")
            payload_sample_id = str(payload.get("sample_id", path.stem))
            if payload_sample_id != sample_id:
                raise ValueError(
                    f"phase label sample_id mismatch for {sample_id}: {payload_sample_id}"
                )
            labels[sample_id] = dict(payload)
        return labels

    def _validate(self) -> None:
        missing_groups = sorted(set(self.sample_fold) - set(self.group_by_sample))
        if missing_groups:
            raise ValueError(f"development samples missing capture groups: {missing_groups[:5]}")
        missing_manifest = sorted(set(self.sample_fold) - set(self.manifest))
        if missing_manifest:
            raise ValueError(f"development samples missing sample manifest rows: {missing_manifest[:5]}")
        missing_labels = sorted(set(self.sample_fold) - set(self.phase_labels))
        if missing_labels:
            raise ValueError(f"development samples missing phase-a labels: {missing_labels[:5]}")

    def is_domain(self, sample_id: str, domain: str = DEFAULT_DOMAIN) -> bool:
        if domain == "all":
            return True
        if domain != DEFAULT_DOMAIN:
            raise ValueError(f"unknown protocol domain: {domain!r}")
        return self.phase_labels[sample_id].get("source_type") == "iso_21496_1_tmap"

    def ids_for_folds(
        self,
        folds: Iterable[int],
        *,
        domain: str = DEFAULT_DOMAIN,
    ) -> list[str]:
        requested = {int(fold) for fold in folds}
        if not requested or not requested.issubset(set(range(5))):
            raise ValueError(f"folds must be a non-empty subset of 0..4, got {sorted(requested)}")
        return [
            sample_id
            for sample_id, fold in self.sample_fold.items()
            if fold in requested and self.is_domain(sample_id, domain)
        ]

    def claim_test_v2_access(
        self,
        *,
        entrypoint: str,
        protocol_id: str,
        artifact_kind: str,
        artifact_sha256: str,
    ) -> OneShotTestV2Claim:
        """Consume the dataset-wide one-shot capability before reading test IDs.

        The ledger name is derived from the test hash frozen in
        ``cv-folds-v1.json``.  Exclusive creation happens before this process
        hashes or parses ``splits/test.json``; an existing ledger in any state
        therefore means the capability is already spent.
        """
        entrypoint = str(entrypoint).strip()
        protocol_id = str(protocol_id).strip()
        artifact_kind = str(artifact_kind).strip()
        artifact_sha256 = str(artifact_sha256).lower()
        if not entrypoint or not protocol_id or not artifact_kind:
            raise ValueError(
                "one-shot claimant entrypoint, protocol_id, and artifact_kind are required"
            )
        if len(artifact_sha256) != 64 or any(
            character not in "0123456789abcdef"
            for character in artifact_sha256
        ):
            raise ValueError("one-shot claim requires a valid artifact SHA-256")

        ledger_path = (
            self.root
            / "reports"
            / "one-shot-ledgers"
            / f"test-split-{self.test_split_sha256}.json"
        )
        ledger_path.parent.mkdir(parents=True, exist_ok=True)
        claimed_utc = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        payload = {
            "ledger_schema": TEST_LEDGER_SCHEMA,
            "test_split_sha256": self.test_split_sha256,
            "state": "claimed",
            "claimed_utc": claimed_utc,
            "claimant": {
                "entrypoint": entrypoint,
                "protocol_id": protocol_id,
                "artifact_kind": artifact_kind,
                "artifact_sha256": artifact_sha256,
            },
        }
        try:
            with ledger_path.open("x", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True, allow_nan=False)
                handle.write("\n")
        except FileExistsError as exc:
            raise RuntimeError(
                "test-v2 one-shot capability is already claimed or consumed: "
                f"{ledger_path}"
            ) from exc
        return OneShotTestV2Claim(
            ledger_path=ledger_path,
            protocol_id=protocol_id,
            test_split_sha256=self.test_split_sha256,
            entrypoint=entrypoint,
            artifact_kind=artifact_kind,
            artifact_sha256=artifact_sha256,
        )

    def _write_test_ledger(self, path: Path, payload: Mapping[str, object]) -> None:
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n",
            encoding="utf-8",
        )

    def ids_for_test_v2(
        self,
        *,
        claim: OneShotTestV2Claim,
        domain: str = DEFAULT_DOMAIN,
    ) -> list[str]:
        """Lazily parse test membership after a verified one-shot claim.

        A bare boolean is intentionally insufficient.  The claim must match
        the fixed dataset-wide ledger, protocol identity, immutable artifact
        hash, and the test hash frozen before this process began.
        """
        if not isinstance(claim, OneShotTestV2Claim):
            raise TypeError("ids_for_test_v2 requires a OneShotTestV2Claim")
        expected_ledger = (
            self.root
            / "reports"
            / "one-shot-ledgers"
            / f"test-split-{self.test_split_sha256}.json"
        ).resolve()
        if claim.ledger_path.resolve() != expected_ledger:
            raise ValueError("one-shot claim does not use the dataset-wide ledger path")
        ledger = _read_json(expected_ledger)
        if not isinstance(ledger, Mapping):
            raise ValueError("one-shot ledger is not a JSON object")
        claimant = ledger.get("claimant")
        if not isinstance(claimant, Mapping):
            raise ValueError("one-shot ledger has no claimant record")
        expected_fields = {
            "ledger_schema": TEST_LEDGER_SCHEMA,
            "test_split_sha256": self.test_split_sha256,
            "state": "claimed",
        }
        for key, expected in expected_fields.items():
            if ledger.get(key) != expected:
                raise ValueError(f"one-shot ledger {key} mismatch")
        claim_fields = {
            "entrypoint": claim.entrypoint,
            "protocol_id": claim.protocol_id,
            "artifact_kind": claim.artifact_kind,
            "artifact_sha256": claim.artifact_sha256,
        }
        for key, expected in claim_fields.items():
            if claimant.get(key) != expected:
                raise ValueError(f"one-shot claimant {key} mismatch")
        if claim.test_split_sha256 != self.test_split_sha256:
            raise ValueError("one-shot claim test hash mismatch")

        mutable_ledger = dict(ledger)
        try:
            actual_sha256 = sha256_file(self.test_split_path)
            if actual_sha256 != self.test_split_sha256:
                raise ValueError(
                    "test split differs from the hash frozen in cv-folds-v1.json"
                )
            test_payload = _read_json(self.test_split_path)
            if not isinstance(test_payload, Mapping):
                raise ValueError("test split is not a JSON object")
            raw_ids = test_payload.get("sample_ids")
            if not isinstance(raw_ids, list) or not raw_ids:
                raise ValueError("test split has no sample_ids")
            test_ids = [str(sample_id) for sample_id in raw_ids]
            if len(test_ids) != len(set(test_ids)) or any(not item for item in test_ids):
                raise ValueError("test split contains empty or duplicate sample IDs")
            overlap = sorted(set(test_ids) & set(self.sample_fold))
            if overlap:
                raise ValueError(f"test-v2 overlaps development folds: {overlap[:5]}")

            test_id_set = set(test_ids)
            test_groups, test_group_by_sample = self._load_groups(test_id_set)
            test_manifest = self._load_manifest_rows(test_id_set)
            test_phase_labels = self._load_phase_labels(test_id_set)
            missing_groups = sorted(test_id_set - set(test_group_by_sample))
            missing_manifest = sorted(test_id_set - set(test_manifest))
            missing_labels = sorted(test_id_set - set(test_phase_labels))
            if missing_groups or missing_manifest or missing_labels:
                raise ValueError(
                    "test-v2 samples lack required metadata: "
                    f"groups={missing_groups[:5]}, "
                    f"manifest={missing_manifest[:5]}, labels={missing_labels[:5]}"
                )
            overlapping_groups = sorted(
                set(test_group_by_sample.values()) & set(self.group_by_sample.values())
            )
            if overlapping_groups:
                raise ValueError(
                    "test-v2 shares capture groups with development folds: "
                    f"{overlapping_groups[:5]}"
                )
            if domain == "all":
                result = list(test_ids)
            elif domain == DEFAULT_DOMAIN:
                result = [
                    sample_id
                    for sample_id in test_ids
                    if test_phase_labels[sample_id].get("source_type")
                    == "iso_21496_1_tmap"
                ]
            else:
                raise ValueError(f"unknown protocol domain: {domain!r}")

            # Publish test metadata only after every post-claim check succeeds.
            self.groups.extend(test_groups)
            self.group_by_sample.update(test_group_by_sample)
            self.manifest.update(test_manifest)
            self.phase_labels.update(test_phase_labels)
        except Exception as exc:
            mutable_ledger.update(
                {
                    "state": "failed_after_claim",
                    "failed_utc": datetime.now(timezone.utc)
                    .isoformat()
                    .replace("+00:00", "Z"),
                    "failure_type": type(exc).__name__,
                    "failure": str(exc),
                }
            )
            self._write_test_ledger(expected_ledger, mutable_ledger)
            raise

        mutable_ledger.update(
            {
                "state": "consumed",
                "consumed_utc": datetime.now(timezone.utc)
                .isoformat()
                .replace("+00:00", "Z"),
                "actual_test_split_sha256": actual_sha256,
                "sample_count": len(test_ids),
            }
        )
        self._write_test_ledger(expected_ledger, mutable_ledger)
        return result

    def group_ids(self, sample_ids: Iterable[str]) -> dict[str, str]:
        result: dict[str, str] = {}
        for sample_id in sample_ids:
            sample_id = str(sample_id)
            try:
                result[sample_id] = self.group_by_sample[sample_id]
            except KeyError as exc:
                raise ValueError(f"sample lacks capture-group assignment: {sample_id}") from exc
        return result

    def endpoint_target(self, sample_id: str) -> EndpointTarget:
        annotation = self.phase_labels[str(sample_id)]
        metadata = annotation.get("gain_metadata")
        if not isinstance(metadata, Mapping):
            raise ValueError(f"{sample_id}: phase label lacks gain_metadata")
        minimum = _finite(_rational_value(metadata["gain_min"]), f"{sample_id} gain_min")
        maximum = _finite(_rational_value(metadata["gain_max"]), f"{sample_id} gain_max")
        if not minimum < maximum:
            raise ValueError(f"{sample_id}: endpoint metadata is not ordered")
        return EndpointTarget(minimum, maximum)

    def fingerprint(self) -> dict[str, str]:
        return {
            "split_manifest": sha256_file(self.split_manifest_path),
            "test_split": self.test_split_sha256,
            "groups": sha256_file(self.groups_path),
            "samples_manifest": sha256_file(self.samples_manifest_path),
        }


def fit_nonnegative_affine(
    feature: Sequence[float],
    target: Sequence[float],
    *,
    feature_name: str,
) -> AffineMap:
    x = np.asarray(feature, dtype=np.float64)
    y = np.asarray(target, dtype=np.float64)
    if x.ndim != 1 or y.ndim != 1 or len(x) != len(y) or len(x) == 0:
        raise ValueError("affine calibration requires equally sized, non-empty vectors")
    if not np.isfinite(x).all() or not np.isfinite(y).all():
        raise ValueError("affine calibration inputs must be finite")
    x_mean = float(x.mean())
    y_mean = float(y.mean())
    denominator = float(np.square(x - x_mean).sum())
    if denominator <= np.finfo(np.float64).eps:
        slope = 0.0
    else:
        slope = max(0.0, float(((x - x_mean) * (y - y_mean)).sum() / denominator))
    intercept = y_mean - slope * x_mean
    return AffineMap(feature_name, slope, _finite(intercept, f"{feature_name} intercept"), len(x))


def _group_mean_rows(rows: Sequence[Mapping[str, object]]) -> list[dict[str, float | str]]:
    grouped: dict[str, list[Mapping[str, object]]] = defaultdict(list)
    for row in rows:
        group_id = str(row["group_id"])
        grouped[group_id].append(row)
    result: list[dict[str, float | str]] = []
    for group_id in sorted(grouped):
        group_rows = grouped[group_id]
        result.append(
            {
                "group_id": group_id,
                "raw_min": float(np.mean([float(row["raw_min"]) for row in group_rows])),
                "raw_max": float(np.mean([float(row["raw_max"]) for row in group_rows])),
                "target_min": float(np.mean([float(row["target_min"]) for row in group_rows])),
                "target_max": float(np.mean([float(row["target_max"]) for row in group_rows])),
                "images": len(group_rows),
            }
        )
    return result


def fit_endpoint_calibration(
    rows: Sequence[Mapping[str, object]],
    *,
    epsilon: float = CALIBRATION_EPSILON,
) -> dict[str, object]:
    """Fit fold-4 endpoint maps using one equal-weight row per group."""
    group_rows = _group_mean_rows(rows)
    if not group_rows:
        raise ValueError("cannot fit endpoint calibration without rows")
    minimum = fit_nonnegative_affine(
        [float(row["raw_min"]) for row in group_rows],
        [float(row["target_min"]) for row in group_rows],
        feature_name="gain_min",
    )
    maximum = fit_nonnegative_affine(
        [float(row["raw_max"]) for row in group_rows],
        [float(row["target_max"]) for row in group_rows],
        feature_name="gain_max",
    )
    ordering = []
    for row in rows:
        calibrated_min = minimum.apply(float(row["raw_min"]))
        calibrated_max = maximum.apply(float(row["raw_max"]))
        if not calibrated_min + epsilon < calibrated_max:
            raise ValueError(
                "calibrated endpoint ordering guard failed for "
                f"{row.get('sample_id', row.get('group_id'))}: "
                f"{calibrated_min} !< {calibrated_max}"
            )
        ordering.append(
            {
                "sample_id": str(row.get("sample_id", "")),
                "calibrated_min": calibrated_min,
                "calibrated_max": calibrated_max,
            }
        )
    return {
        "method": "selection_fold_affine_endpoint_calibration",
        "application_semantics": {
            M_PRESERVING_AFFINE_STRETCH_DIAGNOSTIC_ARM: (
                "keep self-derived M fixed and stretch canonical G; diagnostic only"
            ),
            G_PRESERVING_METADATA_ENVELOPE_ARM: (
                "use calibrated endpoints as a metadata envelope and recompute M "
                "while preserving predicted G; invalid if the envelope excludes G"
            ),
        },
        "epsilon": epsilon,
        "rows": len(rows),
        "capture_groups": len(group_rows),
        "group_rows": group_rows,
        "gain_min": asdict(minimum),
        "gain_max": asdict(maximum),
        "ordering_guard": ordering,
    }


def fit_outward_median_envelope_calibration(
    rows: Sequence[Mapping[str, object]],
) -> dict[str, object]:
    """Fit two non-negative, capture-group-equal outward expansions.

    The lower endpoint is always ``raw_min - lower_expansion`` and the upper
    endpoint is always ``raw_max + upper_expansion``.  Consequently the fitted
    metadata interval contains the predicted canonical G for every possible
    score sample; calibration can never obtain a better endpoint score by
    clipping or changing G.

    Each capture group first contributes the mean expansion required by its
    images.  The median across groups is then used because the registered
    endpoint objective is absolute error and capture groups, not images, are
    the equal-weight statistical units.
    """
    if not rows:
        raise ValueError("cannot fit outward envelope calibration without rows")
    by_group: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for row in rows:
        group_id = str(row.get("group_id", "")).strip()
        if not group_id:
            raise ValueError("outward envelope calibration row has no group_id")
        raw_min = _finite(float(row["raw_min"]), "raw gain_min")
        raw_max = _finite(float(row["raw_max"]), "raw gain_max")
        target_min = _finite(float(row["target_min"]), "target gain_min")
        target_max = _finite(float(row["target_max"]), "target gain_max")
        if not raw_min < raw_max:
            raise ValueError(f"raw endpoint ordering failed for group {group_id}")
        if not target_min < target_max:
            raise ValueError(f"target endpoint ordering failed for group {group_id}")
        by_group[group_id].append(
            (
                max(0.0, raw_min - target_min),
                max(0.0, target_max - raw_max),
            )
        )

    group_rows = [
        {
            "group_id": group_id,
            "images": len(values),
            "lower_required_expansion_stops": float(
                np.mean([value[0] for value in values])
            ),
            "upper_required_expansion_stops": float(
                np.mean([value[1] for value in values])
            ),
        }
        for group_id, values in sorted(by_group.items())
    ]
    lower = float(
        np.median(
            [float(row["lower_required_expansion_stops"]) for row in group_rows]
        )
    )
    upper = float(
        np.median(
            [float(row["upper_required_expansion_stops"]) for row in group_rows]
        )
    )
    return {
        "method": OUTWARD_MEDIAN_ENVELOPE_METHOD,
        "rows": len(rows),
        "capture_groups": len(group_rows),
        "lower_expansion_stops": lower,
        "upper_expansion_stops": upper,
        "group_rows": group_rows,
        "constraints": {
            "gain_min": "raw_min - lower_expansion_stops",
            "gain_max": "raw_max + upper_expansion_stops",
            "lower_expansion_nonnegative": True,
            "upper_expansion_nonnegative": True,
            "preserves_predicted_g": True,
            "valid_for_every_finite_nonconstant_prediction": True,
        },
    }


def apply_outward_median_envelope_calibration(
    prediction: np.ndarray,
    calibration: Mapping[str, object],
    *,
    epsilon: float = CALIBRATION_EPSILON,
) -> EndpointArmEncoding:
    """Apply a fitted outward envelope without changing predicted G."""
    if calibration.get("method") != OUTWARD_MEDIAN_ENVELOPE_METHOD:
        raise ValueError("wrong calibration method for outward metadata envelope")
    lower = _finite(
        float(calibration["lower_expansion_stops"]), "lower endpoint expansion"
    )
    upper = _finite(
        float(calibration["upper_expansion_stops"]), "upper endpoint expansion"
    )
    if lower < 0.0 or upper < 0.0:
        raise ValueError("outward endpoint expansions must be non-negative")
    values, raw_min, raw_max = _validated_prediction(prediction, epsilon=epsilon)
    return apply_g_preserving_metadata_envelope(
        values,
        envelope_min=raw_min - lower,
        envelope_max=raw_max + upper,
        epsilon=epsilon,
    )


def _validated_prediction(
    prediction: np.ndarray,
    *,
    epsilon: float,
) -> tuple[np.ndarray, float, float]:
    values = np.asarray(prediction, dtype=np.float32)
    if values.size == 0:
        raise ValueError("prediction is empty")
    if not np.isfinite(values).all():
        raise ValueError("prediction contains non-finite values")
    raw_min = float(values.min())
    raw_max = float(values.max())
    if not raw_min + epsilon < raw_max:
        raise ValueError(f"raw prediction endpoint ordering failed: {raw_min}, {raw_max}")
    return values, raw_min, raw_max


def _endpoint_arm_encoding(
    *,
    arm: str,
    canonical_gain: np.ndarray,
    encoded_m: np.ndarray,
    gain_min: float,
    gain_max: float,
    raw_min: float,
    raw_max: float,
) -> EndpointArmEncoding:
    gain32 = np.asarray(canonical_gain, dtype=np.float32)
    encoded32 = np.asarray(encoded_m, dtype=np.float32)
    gain64 = gain32.astype(np.float64)
    encoded64 = encoded32.astype(np.float64)
    reconstructed = gain_min + (gain_max - gain_min) * encoded64
    max_error = float(np.max(np.abs(reconstructed - gain64)))
    return EndpointArmEncoding(
        arm=arm,
        canonical_gain=gain32,
        encoded_m=encoded32,
        gain_min=float(gain_min),
        gain_max=float(gain_max),
        raw_min=float(raw_min),
        raw_max=float(raw_max),
        max_abs_reconstruction_error=max_error,
    )


def self_derived_endpoint_arm(
    prediction: np.ndarray,
    *,
    epsilon: float = CALIBRATION_EPSILON,
) -> EndpointArmEncoding:
    """Encode predicted G with its own extrema as metadata endpoints.

    This arm preserves both G and the prediction's self-derived normalized M.
    """
    values, raw_min, raw_max = _validated_prediction(prediction, epsilon=epsilon)
    encoded_m = (
        values.astype(np.float64) - raw_min
    ) / (raw_max - raw_min)
    return _endpoint_arm_encoding(
        arm=SELF_DERIVED_ARM,
        canonical_gain=values,
        encoded_m=encoded_m,
        gain_min=raw_min,
        gain_max=raw_max,
        raw_min=raw_min,
        raw_max=raw_max,
    )


def apply_m_preserving_affine_stretch_diagnostic(
    prediction: np.ndarray,
    *,
    calibrated_min: float,
    calibrated_max: float,
    epsilon: float = CALIBRATION_EPSILON,
) -> EndpointArmEncoding:
    """Keep self-derived M fixed while stretching G to calibrated endpoints.

    This is the historical ``apply_endpoint_calibration`` operation.  It
    changes canonical G and is therefore an affine-stretch *diagnostic*, not a
    metadata-only or G-preserving posterior-calibration arm.
    """
    values, raw_min, raw_max = _validated_prediction(prediction, epsilon=epsilon)
    if not calibrated_min + epsilon < calibrated_max:
        raise ValueError(f"calibrated endpoint ordering failed: {calibrated_min}, {calibrated_max}")
    encoded_m = (
        values.astype(np.float64) - raw_min
    ) / (raw_max - raw_min)
    stretched_gain = calibrated_min + (calibrated_max - calibrated_min) * encoded_m
    if not np.isfinite(stretched_gain).all():
        raise ValueError("calibrated prediction contains non-finite values")
    return _endpoint_arm_encoding(
        arm=M_PRESERVING_AFFINE_STRETCH_DIAGNOSTIC_ARM,
        canonical_gain=stretched_gain,
        encoded_m=encoded_m,
        gain_min=calibrated_min,
        gain_max=calibrated_max,
        raw_min=raw_min,
        raw_max=raw_max,
    )


def apply_g_preserving_metadata_envelope(
    prediction: np.ndarray,
    *,
    envelope_min: float,
    envelope_max: float,
    epsilon: float = CALIBRATION_EPSILON,
) -> EndpointArmEncoding:
    """Re-encode M under calibrated metadata while preserving predicted G.

    The selected metadata interval must contain every predicted G value.  An
    interval that does not contain the prediction is invalid by construction:
    this function never clamps G, clips M, or silently expands the envelope.
    """
    values, raw_min, raw_max = _validated_prediction(prediction, epsilon=epsilon)
    envelope_min = _finite(float(envelope_min), "metadata envelope gain_min")
    envelope_max = _finite(float(envelope_max), "metadata envelope gain_max")
    if not envelope_min + epsilon < envelope_max:
        raise ValueError(
            f"metadata envelope ordering failed: {envelope_min}, {envelope_max}"
        )
    if envelope_min > raw_min or envelope_max < raw_max:
        raise InvalidMetadataEnvelope(
            raw_min=raw_min,
            raw_max=raw_max,
            envelope_min=envelope_min,
            envelope_max=envelope_max,
        )
    encoded_m = (
        values.astype(np.float64) - envelope_min
    ) / (envelope_max - envelope_min)
    if not np.isfinite(encoded_m).all() or np.any(encoded_m < 0.0) or np.any(encoded_m > 1.0):
        raise InvalidMetadataEnvelope(
            raw_min=raw_min,
            raw_max=raw_max,
            envelope_min=envelope_min,
            envelope_max=envelope_max,
        )
    return _endpoint_arm_encoding(
        arm=G_PRESERVING_METADATA_ENVELOPE_ARM,
        canonical_gain=values.copy(),
        encoded_m=encoded_m,
        gain_min=envelope_min,
        gain_max=envelope_max,
        raw_min=raw_min,
        raw_max=raw_max,
    )


def apply_endpoint_calibration(
    prediction: np.ndarray,
    *,
    calibrated_min: float,
    calibrated_max: float,
    epsilon: float = CALIBRATION_EPSILON,
) -> np.ndarray:
    """Compatibility alias for the historical M-preserving diagnostic.

    Existing direct-calibration runners consume the returned stretched G
    array.  New display-domain code must use the explicitly named helpers
    above so this operation cannot be mistaken for metadata-only calibration.
    """
    return apply_m_preserving_affine_stretch_diagnostic(
        prediction,
        calibrated_min=calibrated_min,
        calibrated_max=calibrated_max,
        epsilon=epsilon,
    ).canonical_gain


def capture_group_values(
    rows: Sequence[Mapping[str, object]],
    *,
    value_key: str,
) -> dict[str, float]:
    """Average file values within groups, preserving equal group weighting."""
    grouped: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        grouped[str(row["group_id"])].append(float(row[value_key]))
    if not grouped:
        raise ValueError("cannot aggregate empty capture-group rows")
    return {
        group_id: float(np.mean(values))
        for group_id, values in sorted(grouped.items())
    }


def equal_group_mean(
    rows: Sequence[Mapping[str, object]],
    *,
    value_key: str,
) -> float:
    values = capture_group_values(rows, value_key=value_key)
    return float(np.mean(list(values.values())))


def bootstrap_group_ci(
    rows: Sequence[Mapping[str, object]],
    *,
    value_key: str,
    seed: int = 0,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> dict[str, float | int | str]:
    group_values = np.asarray(
        list(capture_group_values(rows, value_key=value_key).values()),
        dtype=np.float64,
    )
    if len(group_values) == 0:
        raise ValueError("cannot bootstrap empty capture-group rows")
    rng = np.random.default_rng(seed)
    indices = rng.integers(0, len(group_values), size=(resamples, len(group_values)))
    estimates = group_values[indices].mean(axis=1)
    return {
        "metric": value_key,
        "groups": int(len(group_values)),
        "estimate": float(group_values.mean()),
        "ci": "95% two-sided percentile",
        "lower": float(np.percentile(estimates, 2.5)),
        "upper": float(np.percentile(estimates, 97.5)),
        "resamples": int(resamples),
        "seed": int(seed),
    }

