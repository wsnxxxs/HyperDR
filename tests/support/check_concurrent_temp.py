"""Run identical native tests concurrently under one parent TMPDIR."""
import argparse
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executables", nargs="+")
    parser.add_argument("--failure")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="hyperdr-concurrent-") as parent:
        env = dict(os.environ, TMPDIR=parent)
        def run(executable):
            result = subprocess.run([executable], env=env, capture_output=True,
                                    text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(f"{executable}: {result.returncode}\n"
                                   f"{result.stdout}{result.stderr}")
        # Twelve PNG processes reproduced the original failure. Other tests
        # guard the shared helper and the additional fixed-name fixtures.
        jobs = args.executables[:1] * 12 + args.executables[1:] * 4
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(run, jobs))
        if args.failure:
            result = subprocess.run([args.failure], env=env, capture_output=True,
                                    text=True, timeout=90)
            if result.returncode != 1 or "injected TIFF failure" not in result.stderr:
                raise RuntimeError(f"failure probe did not catch the injected exception: {result}")
        remaining = list(Path(parent).iterdir())
        if remaining:
            raise RuntimeError(f"temporary fixtures survived: {remaining}")
        print(f"{len(jobs)} concurrent processes passed under one TMPDIR; cleanup passed (including injected failure)")


if __name__ == "__main__":
    main()
