"""The test runner offers only the product suites."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hyperdr_test_runner", ROOT / "scripts/test.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TestRunnerTest(unittest.TestCase):
    def test_all_runs_the_native_suite_only(self):
        with patch("sys.argv", ["test.py", "all"]), patch.object(runner, "native") as native, \
                patch.object(runner, "apple") as apple:
            self.assertEqual(runner.main(), 0)
        native.assert_called_once()
        apple.assert_not_called()

    def test_the_retired_panel_and_frontend_suites_are_gone(self):
        for suite in ("panel", "frontend"):
            with self.subTest(suite=suite), patch("sys.argv", ["test.py", suite]), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.main()


class IOSEnginePreparationTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifact = self.root / "apps/apple/Packages/HyperDREngine/Artifacts/HyperDREngineCore.xcframework"
        self.root_patch = patch.object(runner, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    def write_artifact(self, platforms=("macos", "ios", "simulator")):
        import plistlib
        self.artifact.mkdir(parents=True, exist_ok=True)
        libraries = []
        for platform in platforms:
            identifier = platform + "-arm64"
            directory = self.artifact / identifier
            (directory / "Headers").mkdir(parents=True, exist_ok=True)
            (directory / "libHyperDREngineCore.a").write_bytes(b"archive")
            for header in ("hyperdr.h", "module.modulemap"):
                (directory / "Headers" / header).write_text("header")
            library = dict(LibraryIdentifier=identifier, LibraryPath="libHyperDREngineCore.a",
                           HeadersPath="Headers", SupportedPlatform="ios" if platform == "simulator" else platform,
                           SupportedArchitectures=["arm64"])
            if platform == "simulator":
                library["SupportedPlatformVariant"] = "simulator"
            libraries.append(library)
        with (self.artifact / "Info.plist").open("wb") as file:
            plistlib.dump(dict(AvailableLibraries=libraries), file)

    def test_complete_artifact_skips_native_rebuild_and_builds_both_apps(self):
        self.write_artifact()
        with patch.object(runner, "xcode_env", return_value={}), \
                patch.object(runner, "ensure_metal_toolchain"), patch.object(runner, "run") as run:
            runner.ios()
        self.assertEqual(run.call_count, 2)
        self.assertTrue(all(call.args[0] == "xcodebuild" for call in run.call_args_list))
        self.assertEqual([call.args[call.args.index("-destination") + 1] for call in run.call_args_list],
                         ["generic/platform=iOS", "generic/platform=iOS Simulator"])

    def test_missing_or_incomplete_artifact_is_rebuilt_before_xcode(self):
        for state in ("absent", "mac-only", "missing-simulator-binary", "invalid-plist", "truncated-plist"):
            with self.subTest(state=state):
                import shutil
                shutil.rmtree(self.artifact, ignore_errors=True)
                if state == "mac-only":
                    self.write_artifact(("macos",))
                elif state == "missing-simulator-binary":
                    self.write_artifact()
                    (self.artifact / "simulator-arm64/libHyperDREngineCore.a").unlink()
                elif state == "invalid-plist":
                    self.artifact.mkdir(parents=True)
                    (self.artifact / "Info.plist").write_bytes(b"not a plist")

                elif state == "truncated-plist":
                    self.artifact.mkdir(parents=True)
                    (self.artifact / "Info.plist").write_bytes(b'<?xml version="1.0"?><plist><dict>')

                def build(*args, **kwargs):
                    if args[0] == "bash":
                        self.write_artifact()
                with patch.object(runner, "xcode_env", return_value={}), \
                        patch.object(runner, "ensure_metal_toolchain"), patch.object(runner, "run", side_effect=build) as run:
                    runner.ios()
                self.assertEqual(run.call_count, 3)
                self.assertEqual(run.call_args_list[0].args,
                                 ("bash", "scripts/build_xcframework.sh", "--platforms", "all"))
                self.assertEqual(run.call_args_list[1].args[0], "xcodebuild")

    def test_incomplete_rebuild_cannot_reach_xcode(self):
        with patch.object(runner, "xcode_env", return_value={}), \
                patch.object(runner, "ensure_metal_toolchain"), patch.object(runner, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "missing usable"):
                runner.ios()
        run.assert_called_once_with("bash", "scripts/build_xcframework.sh", "--platforms", "all", env={})
