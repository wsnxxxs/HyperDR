"""Compare the checked-in settings schema with the selected native build."""
import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SettingsSchemaTest(unittest.TestCase):
    def test_schema_matches_converter(self):
        emitted = subprocess.run(
            [os.environ["HYPERDR_EXECUTABLE"], "schema"],
            capture_output=True, check=True, timeout=30,
        )
        self.assertEqual(
            json.loads(emitted.stdout),
            json.loads((ROOT / "schema/settings.json").read_text(encoding="utf-8")),
            "schema/settings.json is stale; regenerate it with HyperDR schema",
        )
