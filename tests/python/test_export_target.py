"""Saving a finished export to a folder the desktop shell chose.

This is the one route that writes outside the workspace, so the cases worth
pinning are the refusals: a path that is not absolute, one that no longer
exists, one that points back into the workspace, and every route at all when
the server was not built as a local desktop server. The rest covers the two
destinations -- the remembered folder and the one "ask every time" picks, which
must not quietly become the remembered one.
"""
from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import api, export_target, renditions, session  # noqa: E402


class ExportTargetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.previous_root = session.WORK_ROOT
        session.WORK_ROOT = self.root / "workspace"
        session.WORK_ROOT.mkdir()
        self.settings = self.root / "settings" / "export-folder.json"
        self.settings_patch = mock.patch.object(
            export_target, "_settings_file", lambda: self.settings)
        self.settings_patch.start()
        export_target._OPEN_TARGETS.clear()

        self.folder = self.root / "Pictures"
        self.folder.mkdir()
        self.session_id = session.create_session()
        # A rendition is identified by what it was made from, so the session
        # needs a real input before one can be prepared.
        photo = b"\x89PNG\r\n\x1a\n" + b"x" * 64
        session.save_upload(self.session_id, "photo.png", io.BytesIO(photo), len(photo))
        self.context = api.Context(native_path_output=True)

    def tearDown(self):
        self.settings_patch.stop()
        export_target._OPEN_TARGETS.clear()
        session.WORK_ROOT = self.previous_root
        self.temporary.cleanup()

    def publish(self, name="photo.heic", content=b"result"):
        rendition, directory = renditions.prepare(self.session_id, {"encoding": "adaptive"})
        (directory / name).write_bytes(content)
        report = {"files": [{"success": True, "output": str(directory / name)}]}
        return renditions.publish(self.session_id, rendition, report)["id"]

    # -- gating ------------------------------------------------------------ #

    def test_routes_are_absent_without_the_desktop_capability(self):
        """A LAN or phone server must not expose a way to write to this disk."""
        browser = api.Context()
        for response in (
            api.set_export_folder(browser, {"path": str(self.folder)}),
            api.save_to(browser, {"sessionId": self.session_id, "exportId": "x"}),
            api.open_export_folder(browser, {}),
        ):
            self.assertEqual(response.status, 404)
        self.assertFalse(self.settings.exists())

    def test_state_hides_the_folder_from_a_browser_server(self):
        export_target.set_folder(str(self.folder))
        payload = api.state(api.Context(), {}).payload
        self.assertFalse(payload["nativePathOutput"])
        self.assertEqual(payload["exportFolderLabel"], "")
        self.assertFalse(payload["exportFolderReady"])

    # -- choosing a folder -------------------------------------------------- #

    def test_refused_paths(self):
        for path in ("", "Pictures", str(self.folder / "missing"),
                     str(session.WORK_ROOT / "inside")):
            if path.endswith("inside"):
                Path(path).mkdir()
            with self.assertRaises(ValueError, msg=path):
                export_target.set_folder(path)
        self.assertFalse(self.settings.exists())

    def test_a_file_is_not_a_folder(self):
        document = self.folder / "note.txt"
        document.write_text("x", encoding="utf-8")
        with self.assertRaises(ValueError):
            export_target.set_folder(str(document))

    def test_the_write_probe_leaves_nothing_behind(self):
        export_target.set_folder(str(self.folder))
        self.assertEqual(list(self.folder.iterdir()), [])

    def test_state_reports_the_chosen_folder(self):
        api.set_export_folder(self.context, {"path": str(self.folder)})
        payload = api.state(self.context, {}).payload
        self.assertTrue(payload["exportFolderReady"])
        self.assertIn("Pictures", payload["exportFolderLabel"])

    def test_a_short_folder_still_has_a_label(self):
        """Labels stay non-empty without exposing a complete absolute path."""
        anchor = Path(self.folder.anchor)
        self.assertTrue(export_target.folder_label(anchor))
        self.assertNotEqual(export_target.folder_label(anchor), str(anchor))
        short = anchor / "Photos"
        short_label = export_target.folder_label(short)
        self.assertTrue(short_label.startswith("…"))
        self.assertTrue(short_label.endswith("Photos"))
        self.assertNotEqual(short_label, str(short))
        deep = anchor / "a" / "b" / "c"
        self.assertTrue(export_target.folder_label(deep).startswith("…"))
        self.assertTrue(export_target.folder_label(deep).endswith(f"b{os.sep}c"))

    # -- saving ------------------------------------------------------------- #

    def test_save_copies_and_never_overwrites(self):
        export_target.set_folder(str(self.folder))
        first = export_target.save_result(self.session_id, self.publish())
        second = export_target.save_result(self.session_id, self.publish(content=b"again"))
        self.assertEqual(first["name"], "photo.heic")
        self.assertEqual(second["name"], "photo (2).heic")
        self.assertEqual((self.folder / "photo.heic").read_bytes(), b"result")
        self.assertEqual((self.folder / "photo (2).heic").read_bytes(), b"again")

    def test_save_without_a_folder_asks_for_one(self):
        response = api.save_to(
            self.context, {"sessionId": self.session_id, "exportId": self.publish()})
        self.assertEqual(response.status, 400)

    def test_ask_every_time_does_not_redefine_the_fixed_folder(self):
        export_target.set_folder(str(self.folder))
        once = self.root / "Desktop"
        once.mkdir()
        saved = api.save_to(self.context, {
            "sessionId": self.session_id, "exportId": self.publish(), "path": str(once),
        }).payload
        self.assertEqual(saved["name"], "photo.heic")
        self.assertTrue((once / "photo.heic").is_file())
        self.assertFalse((self.folder / "photo.heic").exists())
        self.assertEqual(export_target.selected_folder(), self.folder)

    def test_a_one_off_folder_is_checked_like_any_other(self):
        export_target.set_folder(str(self.folder))
        inside = session.WORK_ROOT / "escape"
        inside.mkdir()
        response = api.save_to(self.context, {
            "sessionId": self.session_id, "exportId": self.publish(), "path": str(inside),
        })
        self.assertEqual(response.status, 400)
        self.assertEqual(list(inside.iterdir()), [])

    def test_preferences_open_remembered_folder_after_one_off_save(self):
        export_target.set_folder(str(self.folder))
        once = self.root / "Desktop"
        once.mkdir()
        export_target.save_result(self.session_id, self.publish(), str(once))
        with self.launcher() as launched:
            response = api.open_export_folder(self.context, {})
        self.assertEqual(response.status, 200)
        self.assertEqual(launched(), self.folder)

    def test_saved_result_token_opens_its_folder_after_a_later_save(self):
        first_folder = self.root / "First"
        second_folder = self.root / "Second"
        first_folder.mkdir()
        second_folder.mkdir()
        first = export_target.save_result(
            self.session_id, self.publish(), str(first_folder))
        export_target.save_result(self.session_id, self.publish(), str(second_folder))
        with self.launcher() as launched:
            response = api.open_export_folder(
                self.context, {"openToken": first["openToken"]})
        self.assertEqual(response.status, 200)
        self.assertEqual(launched(), first_folder)

    def test_open_folder_falls_back_to_the_remembered_one(self):
        export_target.set_folder(str(self.folder))
        with self.launcher() as launched:
            export_target.open_folder()
        self.assertEqual(launched(), self.folder)

    def test_open_folder_without_one_asks_for_one(self):
        self.assertEqual(api.open_export_folder(self.context, {}).status, 400)

    def test_an_unknown_token_is_refused_rather_than_redirected(self):
        """A token the service has forgotten must not quietly open somewhere else."""
        export_target.set_folder(str(self.folder))
        with self.launcher() as launched:
            for token in ("expired", 7):
                response = api.open_export_folder(self.context, {"openToken": token})
                self.assertEqual(response.status, 400, msg=repr(token))
            self.assertFalse(launched.mock.called)

    def launcher(self):
        """Patch whichever file manager this platform would actually start."""
        target = ("startfile", export_target.os) if os.name == "nt" else \
                 ("Popen", export_target.subprocess)
        patch = mock.patch.object(target[1], target[0], create=True)

        class Launcher:
            def __enter__(inner):
                inner.mocked = patch.start()
                def launched():
                    return Path(inner.argument())
                # For the cases whose point is that nothing was opened at all.
                launched.mock = inner.mocked
                return launched
            def __exit__(inner, *_):
                patch.stop()
            def argument(inner):
                (first,), _ = inner.mocked.call_args
                return first[-1] if isinstance(first, list) else first
        return Launcher()


if __name__ == "__main__":
    unittest.main()
