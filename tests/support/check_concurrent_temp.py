"""Run identical native tests concurrently under one parent TMPDIR."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
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
        jobs = [sys.argv[1]] * 12 + sys.argv[2:] * 4
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(run, jobs))
        remaining = list(Path(parent).iterdir())
        if remaining:
            raise RuntimeError(f"temporary fixtures survived: {remaining}")
        print(f"{len(jobs)} concurrent processes passed under one TMPDIR; cleanup passed")


if __name__ == "__main__":
    main()
