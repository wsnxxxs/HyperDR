import json
import pathlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
T2 = ROOT / "tests" / "macos_t2"


class MacOST2ContractTests(unittest.TestCase):
    def test_fixture_pair_and_manifest_are_frozen(self):
        subprocess.run(
            [sys.executable, str(T2 / "generate_fixtures.py"), "verify"],
            cwd=ROOT,
            check=True,
        )

    def test_protocol_has_two_distinct_interior_headrooms_and_gamma_probe(self):
        spec = json.loads((T2 / "fixture_spec.json").read_text(encoding="utf-8"))
        self.assertEqual(spec["protocol_id"], "hyperdr.display-domain/v1/T2")
        self.assertEqual(spec["physical_headroom_stops"], [0.5, 1.0, 1.5])
        self.assertEqual(
            [fixture["gamma"]["numerator"] for fixture in spec["fixtures"]],
            [1, 2],
        )
        self.assertGreater(spec["acceptance"]["probe_alternative_mean_absolute_error_min"], 0)

    def test_workflow_is_manual_single_mac_job(self):
        workflow = (ROOT / ".github" / "workflows" / "macos-display-t2.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertNotIn("schedule:", workflow)
        self.assertEqual(workflow.count("runs-on:"), 1)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertIn("timeout-minutes: 5", workflow)

    def test_report_schema_and_python_entrypoints_parse(self):
        schema = json.loads((T2 / "report.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(
            schema["$id"],
            "https://hyperdr.local/schema/macos-display-t2-report-v1.json",
        )
        for path in (T2 / "generate_fixtures.py", T2 / "validate_t2.py"):
            compile(path.read_text(encoding="utf-8"), str(path), "exec")


if __name__ == "__main__":
    unittest.main()
