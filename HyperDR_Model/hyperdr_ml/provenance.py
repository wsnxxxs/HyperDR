"""Sample provenance, carried from the manifest through training and scoring.

H1 asks for two different things and the second is the one that was missing.
Recording domain, source SHA-256 and label contract per sample was already done
at ingest time in ``manifests/provenance.jsonl``; making those facts *survive
the whole pipeline* was not.  Training and evaluation loaded ``samples.jsonl``
and never opened the provenance ledger, so a checkpoint could not say which
source bytes it was fit to, and a report could not be traced back to a domain
mix.  Provenance that stops at the data tier is a filing convention, not a
traceability guarantee.

Two properties this module is built around:

*Fail closed.*  A sample without a provenance record is an error, not a sample
with unknown provenance.  The failure mode being prevented is a corpus that
grows through a path which forgets to write provenance, where every check still
passes because the check only looked at the rows that happened to be there.

*One number to compare.*  ``source_sha256_digest`` folds the whole set of
per-sample source hashes into a single hash.  A checkpoint stores it, an
evaluation recomputes it, and the two either agree or the run is scored against
different bytes than it was trained on.  Comparing per-sample hashes pairwise at
every stage would be equivalent but would not survive being written into a JSON
report a human is expected to actually check.

Mixing is recorded, not forbidden (H2).  The digest carries the domain, writer
profile and label-contract composition of the exact sample set, so a mixed run
is legible from its own outputs and can be reversed out of the result.  What is
forbidden is mixing that leaves no trace.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

PROVENANCE_NAME = "provenance.jsonl"

# The H1 triple plus the two fields that identify the writer a row came from.
# writer_profile is required because it is the machine-readable writer
# discriminator (the tmap flags byte), and a report that names a domain without
# it cannot distinguish an Apple-strict file from a generic ISO one.
REQUIRED_FIELDS = (
    "sample_id",
    "domain",
    "writer_profile",
    "source_sha256",
    "label_contract_id",
    "label_contract_version",
)

_SHA256_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")
_SAMPLE_ID_FIELD = re.compile(
    rb'"sample_id"\s*:\s*(?P<value>"(?:[^"\\]|\\.)*")'
)


class ProvenanceError(ValueError):
    """A provenance ledger that cannot support an H1 claim about a run."""


def _digest_of_pairs(pairs: list[tuple[str, str]]) -> str:
    """Hash of sorted ``sample_id sha256`` lines.

    Sorted so the digest depends on the *set* of samples and their sources, not
    on split order or loader shuffling; a run and its evaluation reach the same
    value without having to agree on iteration order.
    """
    joined = "".join(f"{sample_id} {source}\n" for sample_id, source in sorted(pairs))
    return sha256(joined.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class ProvenanceLedger:
    """``manifests/provenance.jsonl``, indexed and hashed."""

    path: Path
    file_sha256: str
    rows: dict[str, dict[str, object]]

    @classmethod
    def load(cls, root: str | Path) -> "ProvenanceLedger":
        path = Path(root) / "manifests" / PROVENANCE_NAME
        if not path.exists():
            raise ProvenanceError(
                f"{path} is missing; H1 requires every sample to carry its domain, "
                "source SHA-256 and label contract. Build it with "
                "scripts/ingest_originals.py --rebuild-provenance"
            )
        raw = path.read_bytes()
        rows: dict[str, dict[str, object]] = {}
        for number, line in enumerate(raw.decode("utf-8").splitlines(), start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ProvenanceError(f"{path}:{number} is not valid JSON") from exc
            sample_id = str(row.get("sample_id", ""))
            if not sample_id:
                raise ProvenanceError(f"{path}:{number} has no sample_id")
            if sample_id in rows:
                raise ProvenanceError(
                    f"{path}:{number} repeats sample_id {sample_id!r}; a duplicate "
                    "record makes the ledger's answer depend on which line wins"
                )
            rows[sample_id] = row
        return cls(
            path=path,
            file_sha256=sha256(raw).hexdigest(),
            rows=rows,
        )

    @classmethod
    def load_subset(
        cls,
        root: str | Path,
        sample_ids: list[str] | tuple[str, ...],
    ) -> "ProvenanceLedger":
        """Load only requested records while hashing the complete ledger.

        The full-file SHA-256 remains the corpus identity stored in checkpoints
        and reports.  Held-out rows contribute bytes to that identity, but only
        their ``sample_id`` field is inspected; their remaining metadata is
        neither JSON-decoded nor retained by this ledger instance.
        """

        path = Path(root) / "manifests" / PROVENANCE_NAME
        if not path.exists():
            raise ProvenanceError(
                f"{path} is missing; H1 requires every sample to carry its domain, "
                "source SHA-256 and label contract. Build it with "
                "scripts/ingest_originals.py --rebuild-provenance"
            )
        requested = {str(sample_id) for sample_id in sample_ids}
        rows: dict[str, dict[str, object]] = {}
        file_digest = sha256()
        with path.open("rb") as handle:
            for number, line in enumerate(handle, start=1):
                file_digest.update(line)
                if not line.strip():
                    continue
                match = _SAMPLE_ID_FIELD.search(line)
                if match is None:
                    continue
                try:
                    sample_id = str(json.loads(match.group("value")))
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                if sample_id not in requested:
                    continue
                try:
                    row = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    raise ProvenanceError(
                        f"{path}:{number} is not valid JSON for requested "
                        f"sample {sample_id!r}"
                    ) from exc
                if not isinstance(row, dict):
                    raise ProvenanceError(
                        f"{path}:{number} is not an object for requested "
                        f"sample {sample_id!r}"
                    )
                parsed_id = str(row.get("sample_id", ""))
                if parsed_id != sample_id:
                    raise ProvenanceError(
                        f"{path}:{number} changes sample_id from {sample_id!r} "
                        f"to {parsed_id!r} while parsing"
                    )
                if sample_id in rows:
                    raise ProvenanceError(
                        f"{path}:{number} repeats requested sample_id "
                        f"{sample_id!r}; a duplicate record makes the ledger's "
                        "answer depend on which line wins"
                    )
                rows[sample_id] = row
        return cls(path=path, file_sha256=file_digest.hexdigest(), rows=rows)

    def require(self, sample_ids: list[str] | tuple[str, ...]) -> list[dict[str, object]]:
        """The records for `sample_ids`, or an error naming what is missing.

        Every requested sample must have a complete, well-formed record.  A
        partial record is rejected rather than filled with nulls: a null domain
        in a report reads as "this sample has no domain", which is never true.
        """
        missing = [sample_id for sample_id in sample_ids if sample_id not in self.rows]
        if missing:
            raise ProvenanceError(
                f"{len(missing)} of {len(sample_ids)} sample(s) have no record in "
                f"{self.path} (first: {missing[0]}); provenance must cover every "
                "sample that enters training or evaluation (H1)"
            )
        records = [self.rows[sample_id] for sample_id in sample_ids]
        for record in records:
            absent = [name for name in REQUIRED_FIELDS if record.get(name) is None]
            if absent:
                raise ProvenanceError(
                    f"{record['sample_id']} is missing provenance field(s) "
                    f"{', '.join(absent)}"
                )
            source = str(record["source_sha256"])
            if not _SHA256_PATTERN.match(source):
                raise ProvenanceError(
                    f"{record['sample_id']} has source_sha256={source!r}, which is "
                    "not a lowercase hex SHA-256"
                )
        return records

    def digest(
        self,
        sample_ids: list[str] | tuple[str, ...],
        *,
        run_label_contract_id: str | None = None,
    ) -> dict[str, object]:
        """The provenance fingerprint of one sample set, for a run to store.

        `run_label_contract_id` is the contract the *run* reads, which is not
        always the corpus contract: reproducing the frozen v1 labels reads v1
        grids from a v2-labelled corpus.  That divergence is recorded rather
        than rejected, because it is a legitimate reproduction and H2 asks for a
        record, not a prohibition.
        """
        records = self.require(sample_ids)
        contracts = Counter(
            f"{record['label_contract_id']}@{record['label_contract_version']}"
            for record in records
        )
        result: dict[str, object] = {
            "provenance_path": self.path.name,
            "provenance_sha256": self.file_sha256,
            "samples": len(records),
            "source_sha256_digest": _digest_of_pairs(
                [
                    (str(record["sample_id"]), str(record["source_sha256"]))
                    for record in records
                ]
            ),
            "domains": dict(sorted(Counter(str(r["domain"]) for r in records).items())),
            "writer_profiles": dict(
                sorted(Counter(str(r["writer_profile"]) for r in records).items())
            ),
            "label_contracts": dict(sorted(contracts.items())),
        }
        if run_label_contract_id is not None:
            result["run_label_contract_id"] = run_label_contract_id
            result["run_contract_differs_from_corpus"] = not all(
                str(record["label_contract_id"]) == run_label_contract_id
                for record in records
            )
        return result


def compare_digests(stored: object, current: dict[str, object], *, what: str) -> None:
    """Fail unless a stored provenance digest still describes the corpus.

    `stored` is typed loosely because it arrives from a checkpoint written by an
    older version of this code.  Absent is a failure, not a pass: a check that
    skips when its input is missing certifies exactly the runs it cannot see.
    """
    if not isinstance(stored, dict):
        raise SystemExit(
            f"{what} carries no provenance digest, so its samples' domains and "
            "source hashes cannot be verified (H1). Retrain, or re-stamp it "
            "deliberately if you know which corpus it was fit to."
        )
    for field in ("source_sha256_digest", "provenance_sha256", "samples"):
        if stored.get(field) != current.get(field):
            raise SystemExit(
                f"{what} was fit to a different corpus: provenance {field} is "
                f"{stored.get(field)!r} in the checkpoint and {current.get(field)!r} "
                "on disk"
            )

