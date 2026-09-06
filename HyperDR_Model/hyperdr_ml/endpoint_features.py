"""The registered metadata feature vector for the gain_min attribution.

Frozen by `reports/endpoint-attribution-registration.json`. Two things are done
structurally rather than by care:

*The included set is a whitelist, not the manifest minus a blocklist.* A new
field appearing in `samples.jsonl` must be added here deliberately to be used.
Under a blocklist, a future enrichment pass that added another label-derived
column would silently start feeding the target back to the model, and the arm
would look more predictive for a reason nobody wrote down.

*The excluded names are still listed, and asking for one raises.* Keeping them
written down is what makes the exclusion checkable; a field that is merely
absent looks the same whether it was ruled out or forgotten.

Imputation is fit on training folds only and its rate is reported per feature,
because a feature that is 40% imputed is a constant wearing a name.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

# Every name the registration excludes, with the reason, so a caller that tries
# to reach for one gets the argument rather than a missing-key error.
EXCLUDED_FEATURES: dict[str, str] = {
    "canonical_max_log2_gain": "equals gain_max to 1e-4 and is computed from the MakerNote formula; label-derived",
    "canonical_headroom": "2^gain_max; label-derived",
    "gain_map_headroom_xmp": "label-derived, and null for all 847",
    "headroom_source": "constant across the corpus; describes how the label was resolved",
    "grid_min_log2_gain": "computed from the label pixels",
    "grid_max_log2_gain": "computed from the label pixels",
    "negative_pixel_fraction": "computed from the label pixels",
    "gain_min": "the target",
    "gain_max": "the sibling endpoint, read from the label",
    "alternate_headroom": "read from the label",
    "primary_metadata_sha256": "identifier with no semantics; available only for memorization",
    "source_sha256": "identifier with no semantics",
    "sample_id": "identifier with no semantics",
}

NUMERIC_FEATURES = (
    "iso",
    "exposure_seconds",
    "f_number",
    "exposure_bias_ev",
    "focal_length_mm",
    "focal_length_35mm",
    "apple_maker_hdr_headroom",
    "apple_maker_hdr_gain",
)

DERIVED_FEATURES = (
    "gain_map_width",
    "gain_map_height",
    "primary_width",
    "primary_height",
    "sky_matte_present",
    "color_profile_is_icc",
    "software_ordinal",
    "capture_month_ordinal",
)


class FeatureError(ValueError):
    """A feature request the registration does not permit."""


def software_ordinal(value: object) -> float | None:
    """`major*10000 + minor*100 + patch`, as registered.

    Ordinal rather than one-hot: iOS versions are ordered, and the hypothesis
    the feature exists to test is writer drift over releases, which is a trend
    and not a set of unrelated categories.
    """
    if value is None:
        return None
    parts: list[int] = []
    for piece in str(value).split(".")[:3]:
        try:
            parts.append(int(piece))
        except ValueError:
            return None
    if not parts:
        return None
    parts += [0] * (3 - len(parts))
    return float(parts[0] * 10000 + parts[1] * 100 + parts[2])


def capture_month_ordinal(value: object) -> float | None:
    """Months since year zero, so adjacent months are adjacent numbers."""
    if value is None:
        return None
    try:
        year, month = str(value).split("-")
        return float(int(year) * 12 + int(month))
    except (ValueError, TypeError):
        return None


def _pair(value: object, index: int) -> float | None:
    if not isinstance(value, (list, tuple)) or len(value) <= index:
        return None
    try:
        return float(value[index])
    except (TypeError, ValueError):
        return None


def _number(value: object) -> float | None:
    if value is None or isinstance(value, bool):
        return None if value is None else float(value)
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if np.isfinite(number) else None


def raw_row(sample: dict[str, object], provenance: dict[str, object]) -> dict[str, float | None]:
    """One sample's registered features, before encoding and imputation."""
    row: dict[str, float | None] = {
        name: _number(sample.get(name)) for name in NUMERIC_FEATURES
    }
    row["gain_map_width"] = _pair(sample.get("gain_map_size"), 0)
    row["gain_map_height"] = _pair(sample.get("gain_map_size"), 1)
    row["primary_width"] = _pair(sample.get("primary_size"), 0)
    row["primary_height"] = _pair(sample.get("primary_size"), 1)
    row["sky_matte_present"] = (
        None if sample.get("sky_matte_present") is None
        else float(bool(sample["sky_matte_present"]))
    )
    row["color_profile_is_icc"] = (
        None if sample.get("color_profile") is None
        else float(sample["color_profile"] == "icc")
    )
    row["software_ordinal"] = software_ordinal(sample.get("software"))
    row["capture_month_ordinal"] = capture_month_ordinal(sample.get("capture_month"))
    row["_model"] = sample.get("model")  # one-hot below
    row["_writer_profile"] = provenance.get("writer_profile")
    return row


@dataclass(frozen=True)
class FeatureMatrix:
    names: tuple[str, ...]
    values: np.ndarray
    imputed_fraction: dict[str, float]

    def __post_init__(self) -> None:
        if self.values.shape[1] != len(self.names):
            raise FeatureError(
                f"{self.values.shape[1]} columns for {len(self.names)} names"
            )


class FeatureEncoder:
    """Categorical vocabulary and imputation means, fit on training rows only.

    Fit separately from transform so a judgment fold can never contribute its own
    mean to the imputation of its own features. A category unseen at fit time
    encodes as all-zero rather than growing the matrix, so the column count is a
    property of the fit and not of whatever arrives later.
    """

    def __init__(self) -> None:
        self.models: tuple[str, ...] = ()
        self.writer_profiles: tuple[str, ...] = ()
        self.means: dict[str, float] = {}
        self._fitted = False

    @property
    def names(self) -> tuple[str, ...]:
        if not self._fitted:
            raise FeatureError("encoder is not fitted")
        return (
            NUMERIC_FEATURES
            + DERIVED_FEATURES
            + tuple(f"model={name}" for name in self.models)
            + tuple(f"writer_profile={name}" for name in self.writer_profiles)
        )

    def fit(self, rows: list[dict[str, float | None]]) -> "FeatureEncoder":
        if not rows:
            raise FeatureError("cannot fit an encoder on zero rows")
        self.models = tuple(sorted({str(r["_model"]) for r in rows if r["_model"]}))
        self.writer_profiles = tuple(
            sorted({str(r["_writer_profile"]) for r in rows if r["_writer_profile"]})
        )
        for name in NUMERIC_FEATURES + DERIVED_FEATURES:
            present = [r[name] for r in rows if r[name] is not None]
            if not present:
                raise FeatureError(
                    f"feature {name!r} is missing on every training row; a column "
                    "that is entirely absent cannot be imputed into existence"
                )
            self.means[name] = float(np.mean(present))
        self._fitted = True
        return self

    def transform(self, rows: list[dict[str, float | None]]) -> FeatureMatrix:
        if not self._fitted:
            raise FeatureError("encoder is not fitted")
        columns = NUMERIC_FEATURES + DERIVED_FEATURES
        matrix = np.zeros((len(rows), len(self.names)), dtype=np.float64)
        imputed = {name: 0 for name in columns}
        for index, row in enumerate(rows):
            for position, name in enumerate(columns):
                value = row[name]
                if value is None:
                    value = self.means[name]
                    imputed[name] += 1
                matrix[index, position] = value
            offset = len(columns)
            for position, name in enumerate(self.models):
                matrix[index, offset + position] = float(str(row["_model"]) == name)
            offset += len(self.models)
            for position, name in enumerate(self.writer_profiles):
                matrix[index, offset + position] = float(
                    str(row["_writer_profile"]) == name
                )
        denominator = max(len(rows), 1)
        return FeatureMatrix(
            names=self.names,
            values=matrix,
            imputed_fraction={
                name: count / denominator for name, count in imputed.items()
            },
        )


def check_not_excluded(name: str) -> None:
    """Raise if `name` is one the registration rules out."""
    if name in EXCLUDED_FEATURES:
        raise FeatureError(
            f"{name!r} is excluded from the endpoint attribution feature set: "
            f"{EXCLUDED_FEATURES[name]}"
        )


def load_rows(
    root: str | Path, sample_ids: list[str] | tuple[str, ...]
) -> list[dict[str, float | None]]:
    """Registered raw features for `sample_ids`, in that order."""
    root = Path(root)
    samples = {
        row["sample_id"]: row
        for row in (
            json.loads(line)
            for line in (root / "manifests" / "samples.jsonl").read_text().splitlines()
            if line.strip()
        )
    }
    provenance = {
        row["sample_id"]: row
        for row in (
            json.loads(line)
            for line in (root / "manifests" / "provenance.jsonl").read_text().splitlines()
            if line.strip()
        )
    }
    missing = [s for s in sample_ids if s not in samples or s not in provenance]
    if missing:
        raise FeatureError(
            f"{len(missing)} sample(s) lack a manifest or provenance row "
            f"(first: {missing[0]})"
        )
    return [raw_row(samples[s], provenance[s]) for s in sample_ids]

