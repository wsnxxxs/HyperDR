"""The test runner offers only the product suites."""
import contextlib
import importlib.util
import io
import sys
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hyperdr_test_runner", ROOT / "scripts/test.py")
runner = importlib.util.module_from_spec(spec)
with patch.object(sys, "path", [str(ROOT / "scripts"), *sys.path]):
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
        (self.artifact.parent / "engine-source.sha256").write_text(runner.engine_fingerprint(self.root))

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

    def test_stale_inputs_and_missing_stamp_rebuild_existing_slices(self):
        for changed in ("missing-stamp", "modules/image/new.cpp", "cmake/new.cmake",
                        "vcpkg.json", "scripts/build_xcframework.sh",
                        "HyperDR_Model/models/research-cnn-v1.ncnn.bin"):
            with self.subTest(changed=changed):
                self.write_artifact()
                if changed == "missing-stamp":
                    (self.artifact.parent / "engine-source.sha256").unlink()
                else:
                    source = self.root / changed
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_text("new engine content")
                with patch.object(runner, "run", side_effect=lambda *args, **kwargs: self.write_artifact()) as run:
                    runner.ensure_ios_engine({})
                run.assert_called_once_with("bash", "scripts/build_xcframework.sh", "--platforms", "all", env={})

    def test_mac_uses_current_slice_but_rebuilds_changed_engine(self):
        self.write_artifact(("macos",))
        with patch.object(runner, "run") as run:
            runner.ensure_apple_engine({}, ios=False)
        run.assert_not_called()
        source = self.root / "modules/core.cpp"
        source.parent.mkdir(parents=True)
        source.write_text("changed")
        with patch.object(runner, "run", side_effect=lambda *args, **kwargs: self.write_artifact(("macos",))) as run:
            runner.ensure_apple_engine({}, ios=False)
        run.assert_called_once_with("bash", "scripts/build_xcframework.sh", env={})

    def test_unrelated_UI_edits_do_not_invalidate_engine_but_deletions_do(self):
        source = self.root / "modules/core.cpp"
        source.parent.mkdir(parents=True)
        source.write_text("engine")
        before = runner.engine_fingerprint(self.root)
        (self.root / "View.swift").write_text("UI only")
        self.assertEqual(before, runner.engine_fingerprint(self.root))
        source.unlink()
        self.assertNotEqual(before, runner.engine_fingerprint(self.root))

    def test_only_embedded_model_bin_change_invalidates_the_fingerprint(self):
        models = self.root / "HyperDR_Model/models"
        models.mkdir(parents=True)
        weights = models / "research-cnn-v1.ncnn.bin"
        weights.write_bytes(b"old weights")
        before = runner.engine_fingerprint(self.root)
        weights.write_bytes(b"new weights")
        after = runner.engine_fingerprint(self.root)
        self.assertNotEqual(before, after)
        # These are not inputs to the native embedded-model build.
        (models / "training-checkpoint.pt").write_bytes(b"training")
        swift_weights = models / "research-cnn-v1.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        swift_weights.parent.mkdir(parents=True)
        swift_weights.write_bytes(b"CoreML")
        self.assertEqual(after, runner.engine_fingerprint(self.root))

    def test_first_build_checks_stamp_beside_new_artifact_symlink(self):
        def build(*args, **kwargs):
            output = self.root / "build/xcframework/HyperDREngineCore.xcframework"
            output.mkdir(parents=True)
            self.artifact.parent.mkdir(parents=True)
            self.artifact.symlink_to(output, target_is_directory=True)
            self.write_artifact()
            (output.parent / "engine-source.sha256").write_text(runner.engine_fingerprint(self.root))
            (self.artifact.parent / "engine-source.sha256").unlink()
        with patch.object(runner, "run", side_effect=build) as run:
            runner.ensure_ios_engine({})
        self.assertEqual(run.call_count, 1)

    def test_rebuild_without_fresh_stamp_is_rejected(self):
        self.write_artifact()
        (self.artifact.parent / "engine-source.sha256").write_text("outdated")
        with patch.object(runner, "run"), self.assertRaisesRegex(RuntimeError, "stamp.*stale"):
            runner.ensure_ios_engine({})

    def test_incomplete_rebuild_cannot_reach_xcode(self):
        with patch.object(runner, "xcode_env", return_value={}), \
                patch.object(runner, "ensure_metal_toolchain"), patch.object(runner, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "missing usable"):
                runner.ios()
        run.assert_called_once_with("bash", "scripts/build_xcframework.sh", "--platforms", "all", env={})
