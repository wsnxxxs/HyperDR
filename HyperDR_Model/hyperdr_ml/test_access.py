"""Shared checkpoint gate for the dataset-wide one-shot test split.

The exclusive ledger and delayed test-membership read live in
``hyperdr_ml.protocol``.  This module adds the checkpoint-specific checks used
by evaluators: the embedded semantic config hash must be self-consistent, every
development split file used to reconstruct the run must still match, and the
checkpoint's frozen test hash must equal the registration before the global
claim is attempted.

Development validation deliberately never opens ``splits/test.json`` and never
touches the one-shot ledger.  The actual test file is first hashed and parsed by
``AppleProtocolCorpus.ids_for_test_v2`` *after* exclusive creation succeeds.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from hyperdr_ml.phase_a_labels import sha256_file
from hyperdr_ml.protocol import (
    DEFAULT_SPLIT_MANIFEST,
    AppleProtocolCorpus,
    OneShotTestV2Claim,
)


TEST_SPLIT_NAME = "test.json"
DEVELOPMENT_SPLIT_NAMES = ("groups.json", "train.json", "validation.json")


class CheckpointIdentityError(ValueError):
    """A checkpoint cannot prove the config or split identity it claims."""


@dataclass(frozen=True)
class CheckpointTestAccess:
    """Capability produced only after the global ledger and test hash checks."""

    claim: OneShotTestV2Claim
    checkpoint_sha256: str
    registered_test_split_sha256: str
    validated_test_ids: tuple[str, ...]

    @property
    def data_capability(self) -> bool:
        """Value accepted by AppleGainMapDataset's fail-closed test gate."""
        return True


def _checkpoint_config_sha256(config: Mapping[str, object]) -> str:
    # Keep one source of truth for the semantic hash written by train.py.  The
    # import is lazy so importing this lightweight gate never initializes the
    # training entrypoint or Torch unless a checkpoint is actually validated.
    from train import config_sha256

    return config_sha256(dict(config))


def validate_checkpoint_config_hash(
    checkpoint: Mapping[str, object],
) -> Mapping[str, object]:
    """Require the embedded config and config_sha256 to agree exactly."""
    config = checkpoint.get("config")
    if not isinstance(config, Mapping):
        raise CheckpointIdentityError("checkpoint has no configuration mapping")
    stored = checkpoint.get("config_sha256")
    if not isinstance(stored, str) or not stored:
        raise CheckpointIdentityError(
            "checkpoint carries no config_sha256; its training configuration "
            "cannot be authenticated"
        )
    try:
        actual = _checkpoint_config_sha256(config)
    except (TypeError, ValueError) as exc:
        raise CheckpointIdentityError(
            f"checkpoint configuration is not canonically hashable: {exc}"
        ) from exc
    if stored != actual:
        raise CheckpointIdentityError(
            "checkpoint config_sha256 does not match its embedded configuration"
        )
    return config


def checkpoint_split_hashes(
    checkpoint: Mapping[str, object],
) -> Mapping[str, object]:
    """Presence-required split hash mapping from a reproducible checkpoint."""
    stored = checkpoint.get("split_sha256")
    if not isinstance(stored, Mapping):
        raise CheckpointIdentityError(
            "checkpoint carries no split_sha256 mapping; its data partition "
            "cannot be authenticated"
        )
    if TEST_SPLIT_NAME not in stored:
        raise CheckpointIdentityError(
            "checkpoint split_sha256 has no test.json registration"
        )
    return stored


def validate_checkpoint_development_split_hashes(
    root: str | Path,
    checkpoint: Mapping[str, object],
    *,
    fold: int | None,
) -> Mapping[str, object]:
    """Validate run-defining split files without touching test.json or a ledger."""
    stored = checkpoint_split_hashes(checkpoint)
    names = list(DEVELOPMENT_SPLIT_NAMES)
    if fold is not None:
        names.append(Path(DEFAULT_SPLIT_MANIFEST).name)
    splits = Path(root) / "splits"
    for name in names:
        expected = stored.get(name)
        if not isinstance(expected, str) or not expected:
            raise CheckpointIdentityError(
                f"checkpoint split_sha256 has no {name} hash"
            )
        try:
            actual = sha256_file(splits / name)
        except OSError as exc:
            raise CheckpointIdentityError(
                f"cannot authenticate split file {splits / name}: {exc}"
            ) from exc
        if expected != actual:
            raise CheckpointIdentityError(
                f"checkpoint split hash does not match the dataset: {name}"
            )
    return stored


def claim_checkpoint_test_access(
    root: str | Path,
    checkpoint: Mapping[str, object],
    checkpoint_path: str | Path,
    *,
    entrypoint: str,
    protocol_id: str,
) -> CheckpointTestAccess:
    """Claim and validate test access for one checkpoint.

    Ordering is part of the contract:

    1. construct ``AppleProtocolCorpus``, which reads the registered test hash
       from ``cv-folds-v1.json`` but does not stat, hash, or parse test.json;
    2. compare that registration with the checkpoint's split_sha256 mapping;
    3. hash the checkpoint artifact and atomically claim the shared ledger;
    4. only then hash and parse test.json through the claim-bearing protocol API.

    Any exception in step 4 leaves the ledger present and marked failed after
    claim, so changing output directories or retrying cannot restore blindness.
    """
    stored_splits = checkpoint_split_hashes(checkpoint)
    corpus = AppleProtocolCorpus(root)
    registered = corpus.test_split_sha256
    checkpoint_test_hash = stored_splits.get(TEST_SPLIT_NAME)
    if checkpoint_test_hash != registered:
        raise CheckpointIdentityError(
            "checkpoint test.json hash does not match the hash registered in "
            "cv-folds-v1.json; refusing before consuming the one-shot claim"
        )

    try:
        artifact_sha256 = sha256_file(checkpoint_path)
    except OSError as exc:
        raise CheckpointIdentityError(
            f"cannot hash checkpoint artifact {checkpoint_path}: {exc}"
        ) from exc
    claim = corpus.claim_test_v2_access(
        entrypoint=entrypoint,
        protocol_id=protocol_id,
        artifact_kind="checkpoint",
        artifact_sha256=artifact_sha256,
    )
    # This is the first operation that hashes/parses test.json.  It also turns
    # the ledger from claimed into consumed, or failed_after_claim on any error.
    validated_ids = corpus.ids_for_test_v2(claim=claim, domain="all")
    return CheckpointTestAccess(
        claim=claim,
        checkpoint_sha256=artifact_sha256,
        registered_test_split_sha256=registered,
        validated_test_ids=tuple(validated_ids),
    )

