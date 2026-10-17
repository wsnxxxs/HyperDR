"""Fetch the licensed RAW fixtures into build/fixtures and verify their SHA-256."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    destination = ROOT / "build" / "fixtures"
    destination.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "tests/fixtures/manifest.json").read_text())
    for fixture in manifest["fixtures"]:
        target = destination / fixture["filename"]
        if target.is_file() and sha256(target) == fixture["sha256"]:
            print(f"Verified {target.relative_to(ROOT)}", flush=True)
            continue
        request = urllib.request.Request(fixture["url"], headers={"User-Agent": "HyperDR-test-fixtures/1"})
        temporary = None
        try:
            print(f"Downloading {fixture['id']} ({fixture['license']})", flush=True)
            with tempfile.NamedTemporaryFile(dir=destination, suffix=".download", delete=False) as output:
                temporary = Path(output.name)
                with urllib.request.urlopen(request, timeout=60) as source:
                    while block := source.read(1024 * 1024):
                        output.write(block)
            actual = sha256(temporary)
            if actual != fixture["sha256"]:
                raise ValueError(f"SHA-256 mismatch for {fixture['id']}: {actual}")
            temporary.replace(target)
            print(f"Verified {target.relative_to(ROOT)}", flush=True)
        except (OSError, ValueError) as error:
            print(f"Fixture download failed: {error}. Retry: python3 scripts/fetch_test_fixtures.py", file=sys.stderr)
            return 1
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
