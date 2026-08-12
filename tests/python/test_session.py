"""One session, one image.

These cases pin the properties that are cheap to assert and expensive to get
wrong: a browser-supplied name cannot escape the session, content must match the
extension it claims, a replacement leaves nothing behind, and cleanup never
removes files a conversion is still reading.
"""
from __future__ import annotations

import io
import os
import tempfile
import time
import unittest
from pathlib import Path

from apps.panel.hyperdr_panel import session

PNG = b"\x89PNG\r\n\x1a\n" + b"x" * 32
JPEG = b"\xff\xd8\xff\xe0" + b"y" * 32


def upload(session_id: str, name: str, data: bytes = PNG):
    return session.save_upload(session_id, name, io.BytesIO(data), len(data))


def age(path: Path, seconds: float) -> None:
    stamp = time.time() - seconds
    os.utime(path, (stamp, stamp))


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_root = session.WORK_ROOT
        session.WORK_ROOT = Path(self.temporary.name).resolve()

    def tearDown(self):
        session.WORK_ROOT = self.previous_root
        self.temporary.cleanup()

    # --- upload ----------------------------------------------------------- #

    def test_upload_is_isolated_and_sanitized(self):
        session_id = session.create_session()
        target, written = upload(session_id, "../../evil name.png")
        self.assertEqual(written, len(PNG))
        self.assertEqual(target.name, "evil name.png")
        self.assertEqual(target.parent, session.WORK_ROOT / session_id / "input")

    def test_rejects_disguised_content(self):
        session_id = session.create_session()
        with self.assertRaises(ValueError):
            upload(session_id, "actually-text.png", b"not a png at all")

    def test_rejects_an_unsupported_extension(self):
        session_id = session.create_session()
        with self.assertRaises(ValueError):
            upload(session_id, "notes.txt", b"hello")

    def test_rejects_a_file_over_the_limit(self):
        session_id = session.create_session()
        with self.assertRaises(ValueError):
            session.save_upload(session_id, "big.png", io.BytesIO(PNG),
                                session.MAX_UPLOAD_BYTES + 1)

    def test_a_truncated_upload_leaves_nothing_behind(self):
        """A dropped connection must not publish a half-written image."""
        session_id = session.create_session()
        with self.assertRaises(ValueError):
            session.save_upload(session_id, "cut.png", io.BytesIO(PNG), len(PNG) + 4096)
        self.assertEqual(list((session.WORK_ROOT / session_id / "input").iterdir()), [])

    # --- one image at a time ---------------------------------------------- #

    def test_uploading_replaces_the_previous_image(self):
        session_id = session.create_session()
        upload(session_id, "first.png", PNG)
        upload(session_id, "second.jpg", JPEG)
        held = sorted(p.name for p in (session.WORK_ROOT / session_id / "input").iterdir())
        self.assertEqual(held, ["second.jpg"])
        self.assertEqual(session.input_path(session_id).name, "second.jpg")

    def test_a_rejected_replacement_keeps_the_existing_image(self):
        session_id = session.create_session()
        upload(session_id, "good.png", PNG)
        with self.assertRaises(ValueError):
            upload(session_id, "bad.png", b"not a png")
        self.assertEqual(session.input_path(session_id).name, "good.png")

    def test_input_path_reports_an_empty_session(self):
        session_id = session.create_session()
        with self.assertRaises(FileNotFoundError):
            session.input_path(session_id)

    # --- session ids ------------------------------------------------------ #

    def test_unknown_session_ids_are_rejected(self):
        for bad in ("", "..", "../etc", "z" * 32, "0" * 31):
            with self.assertRaises((ValueError, FileNotFoundError)):
                session.session_root(bad)

    def test_only_input_and_output_are_addressable(self):
        session_id = session.create_session()
        for bad in ("..", "preview", "/etc"):
            with self.assertRaises(ValueError):
                session.session_dir(session_id, bad)

    # --- results ---------------------------------------------------------- #

    def test_result_is_found_for_every_encoding_container(self):
        for name in ("photo.heic", "photo.jpg", "photo.avif"):
            session_id = session.create_session()
            (session.WORK_ROOT / session_id / "output" / name).write_bytes(b"result")
            self.assertEqual(session.result_path(session_id).name, name)

    def test_result_ignores_model_intermediate_images(self):
        session_id = session.create_session()
        output = session.WORK_ROOT / session_id / "output"
        for directory in (".model", ".model-preview"):
            intermediate = output / directory
            intermediate.mkdir()
            (intermediate / "model-input-linear-p3.f32").write_bytes(b"tensor")
            (intermediate / "model-input.json").write_text("{}", encoding="utf-8")
        result = output / "photo.jpg"
        result.write_bytes(b"ultra hdr result")

        self.assertEqual(session.result_path(session_id), result)

    def test_result_cannot_escape_the_session(self):
        session_id = session.create_session()
        outside = session.WORK_ROOT / "outside.heic"
        outside.write_bytes(b"result")
        link = session.WORK_ROOT / session_id / "output" / "escape.heic"
        try:
            link.symlink_to(outside)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable")
        with self.assertRaises(ValueError):
            session.result_path(session_id)

    def test_clearing_removes_the_previous_encodings_output(self):
        """Switching HEIC to AVIF must not leave the old file to be found."""
        session_id = session.create_session()
        (session.WORK_ROOT / session_id / "output" / "photo.heic").write_bytes(b"old")
        self.assertEqual(session.clear_output(session_id), 1)
        with self.assertRaises(FileNotFoundError):
            session.result_path(session_id)

    def test_clearing_keeps_the_converters_own_bookkeeping(self):
        session_id = session.create_session()
        output = session.WORK_ROOT / session_id / "output"
        (output / ".hyperdr").mkdir()
        (output / ".hyperdr" / "resume.json").write_text("{}")
        (output / "photo.heic").write_bytes(b"old")
        session.clear_output(session_id)
        self.assertTrue((output / ".hyperdr" / "resume.json").is_file())

    # --- cleanup ---------------------------------------------------------- #

    def test_cleanup_only_removes_expired_sessions(self):
        fresh = session.create_session()
        stale = session.create_session()
        age(session.WORK_ROOT / stale, session.SESSION_TTL_SECONDS + 60)
        self.assertEqual(session.cleanup_expired_sessions(), 1)
        self.assertTrue((session.WORK_ROOT / fresh).is_dir())
        self.assertFalse((session.WORK_ROOT / stale).exists())

    def test_cleanup_preserves_an_active_session(self):
        stale = session.create_session()
        age(session.WORK_ROOT / stale, session.SESSION_TTL_SECONDS + 60)
        self.assertEqual(
            session.cleanup_expired_sessions(protected_session_ids={stale}), 0)
        self.assertTrue((session.WORK_ROOT / stale).is_dir())

    def test_cleanup_ignores_directories_that_are_not_sessions(self):
        stray = session.WORK_ROOT / "not-a-session"
        stray.mkdir(parents=True)
        age(stray, session.SESSION_TTL_SECONDS + 60)
        self.assertEqual(session.cleanup_expired_sessions(), 0)
        self.assertTrue(stray.is_dir())


if __name__ == "__main__":
    unittest.main()
