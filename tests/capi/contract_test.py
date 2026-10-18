"""Compare C ABI streams with the CLI from the same build, without JSON reformatting."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

CLI, LIBRARY = map(str, map(Path, sys.argv[1:3]))
del sys.argv[1:3]
DLL_DIRECTORY = os.add_dll_directory(str(Path(LIBRARY).parent)) if os.name == "nt" else None
LIB = ctypes.CDLL(LIBRARY)


class Error(ctypes.Structure):
    _fields_ = [("code", ctypes.c_char_p), ("message", ctypes.c_char_p)]


LIB.hyperdr_schema_json.argtypes = [ctypes.POINTER(ctypes.c_void_p),
                                   ctypes.POINTER(ctypes.POINTER(Error))]
LIB.hyperdr_curve_json.argtypes = [ctypes.c_char_p, ctypes.c_uint,
                                  *LIB.hyperdr_schema_json.argtypes]
LIB.hyperdr_frame_layout.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32,
                                    *LIB.hyperdr_schema_json.argtypes]
LIB.hyperdr_string_free.argtypes = [ctypes.c_void_p]
LIB.hyperdr_string_free.restype = None
LIB.hyperdr_error_free.argtypes = [ctypes.POINTER(Error)]
LIB.hyperdr_error_free.restype = None


def result(function, *args):
    output = ctypes.c_void_p()
    error = ctypes.POINTER(Error)()
    status = function(*args, ctypes.byref(output), ctypes.byref(error))
    try:
        if status:
            raise AssertionError(error.contents.message.decode() if error else "allocation failed")
        return ctypes.string_at(output)
    finally:
        LIB.hyperdr_string_free(output)
        LIB.hyperdr_error_free(error)


class Contract(unittest.TestCase):



    def test_schema(self):
        self.assertEqual(result(LIB.hyperdr_schema_json),
                         subprocess.check_output([CLI, "schema"]))

    def test_curve(self):
        for settings, samples in [({}, 257), ({"contrast": 1.2, "vibrance": 0.2,
                                             "exposure_bias": -0.5}, 33),
                                   ({"headroom": 2.0, "gain_strength": 0.7}, 4096),
                                   ({"contrast": 1.123456}, 33),
                                   ({"contrast": 1.123456, "vibrance": -.234567,
                                     "exposure_bias": .612345}, 33),
                                   ({"encoding": "avif-hlg", "headroom_max": 4.0}, 65),
                                   ({"raw_profile": "camera.dcp"}, 65),
                                   ({"raw_profile": "camera.dcp", "contrast": 1.2,
                                     "vibrance": 0.2}, 65)]:
            with self.subTest(settings=settings, samples=samples):
                arguments = [CLI, "curve", "--samples", str(samples)]
                for key, value in settings.items():
                    arguments.extend(["--" + key.replace("_", "-"), str(value)])
                expected = subprocess.check_output(arguments)
                self.assertEqual(result(LIB.hyperdr_curve_json,
                                        json.dumps(settings).encode(), samples), expected)

    def test_frame_layout(self):
        import tempfile
        frames = [{"margins": 0.05, "caption": 0.1},
                  {"background": "#F4F2EC", "margins": {"top": 0.06, "right": 0.05, "bottom": 0.04, "left": 0.05},
                   "caption": 0.14, "reference": "long",
                   "aspect": {"width": 9, "height": 16, "topShare": 0.3},
                   "shadow": {"opacity": 0.1, "blur": 0.01, "offset": 0.004}},
                  {"margins": 0.0333, "aspect": {"width": 1, "height": 1}}]
        with tempfile.TemporaryDirectory() as folder:
            for frame in frames:
                for width, height in [(6000, 4000), (1001, 1501), (4032, 3024)]:
                    with self.subTest(frame=frame, size=(width, height)):
                        path = Path(folder) / "frame.json"
                        path.write_text(json.dumps(frame))
                        expected = subprocess.check_output([CLI, "frame-layout", str(path),
                                                            "--width", str(width), "--height", str(height)])
                        self.assertEqual(result(LIB.hyperdr_frame_layout, json.dumps(frame).encode(),
                                                width, height), expected)




# New engine functions use the same allocation/error ownership as the original
# six. Keep raw bytes until assertions: JSON parsing must not conceal differences.
import hashlib
import struct
import tempfile
import threading
import time
import zlib

Handle = ctypes.c_void_p
ErrorOut = ctypes.POINTER(ctypes.POINTER(Error))
StringOut = ctypes.POINTER(ctypes.c_void_p)

class Buffer(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("size", ctypes.c_size_t), ("owner", ctypes.c_void_p)]

class Plane(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("size", ctypes.c_size_t), ("row_bytes", ctypes.c_size_t),
                ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("channels", ctypes.c_uint32), ("format", ctypes.c_uint32)]

class Frame(ctypes.Structure):
    _fields_ = [("metadata_json", ctypes.c_char_p), ("base", Plane), ("gain", Plane), ("owner", Handle)]

CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)
for name, args in {
    "engine_create": [ctypes.c_char_p, ctypes.POINTER(Handle), ErrorOut],
    "engine_destroy": [Handle], "capabilities": [Handle, StringOut, ErrorOut],
    "probe": [Handle, ctypes.c_char_p, StringOut, ErrorOut],
    "raw_metadata": [Handle, ctypes.c_char_p, StringOut, ErrorOut],
    "normalize_options": [ctypes.c_char_p, StringOut, ErrorOut],
    "command_line": [ctypes.c_char_p, StringOut, ErrorOut],
    "preview_open": [Handle, ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(Handle), ErrorOut],
    "preview_close": [Handle],
    "preview_render": [Handle, ctypes.c_char_p, Handle, ctypes.POINTER(Buffer), ErrorOut],
    "preview_render_frame": [Handle, ctypes.c_char_p, Handle, ctypes.POINTER(Frame), ErrorOut],
    "model_gain": [Handle, ctypes.c_char_p, Handle, ctypes.POINTER(Buffer), ErrorOut],
    "convert": [Handle, ctypes.c_char_p, CALLBACK, Handle, Handle, StringOut, ErrorOut],
    "cancel_create": [], "cancel_request": [Handle], "cancel_destroy": [Handle],
    "buffer_free": [ctypes.POINTER(Buffer)], "frame_free": [ctypes.POINTER(Frame)],
}.items():
    function = getattr(LIB, "hyperdr_" + name)
    function.argtypes = args
    if name == "cancel_create":
        function.restype = Handle
    elif name.endswith(("destroy", "close", "free", "request")):
        function.restype = None

def encoded(value):
    return json.dumps(value, ensure_ascii=False).encode()

def checked(function, *args):
    error = ctypes.POINTER(Error)()
    status = function(*args, ctypes.byref(error))
    try:
        if status:
            raise AssertionError((error.contents.code.decode(), error.contents.message.decode()) if error else "allocation failed")
    finally:
        LIB.hyperdr_error_free(error)

def png(path, width, height):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    rows = b"".join(b"\0" + bytes((x * 255 // width, y * 255 // height, 120)[c]
                               for x in range(width) for c in range(3)) for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))

def dcp(path, camera_model="Synthetic"):
    # Minimal identity camera profile; no external camera assets are required.
    matrix = b"".join(struct.pack("<ii", int(i % 4 == 0), 1) for i in range(9))
    camera = camera_model.encode() + b"\0"
    fields = [(50708, 2, len(camera), camera), (50721, 10, 9, matrix),
              (50778, 3, 1, struct.pack("<H", 21)), (50936, 2, 10, b"Synthetic\0")]
    entries, payload = bytearray(), bytearray()
    for tag, kind, count, data in fields:
        entries += struct.pack("<HHI", tag, kind, count)
        if len(data) <= 4:
            entries += data.ljust(4, b"\0")
        else:
            entries += struct.pack("<I", 14 + 12 * len(fields) + len(payload))
            payload += data
    path.write_bytes(b"II" + struct.pack("<HIH", 0x4352, 8, len(fields))
                     + entries + b"\0" * 4 + payload)

def raw_fixture(fixture_id):
    root = Path(__file__).resolve().parents[2]
    manifest = json.loads((root / "tests/fixtures/manifest.json").read_text())
    fixture = next(value for value in manifest["fixtures"] if value["id"] == fixture_id)
    path = root / "build/fixtures" / fixture["filename"]
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != fixture["sha256"]:
        raise AssertionError(f"Required RAW fixture missing or corrupt: {path}. "
                             "Run python3 scripts/fetch_test_fixtures.py")
    return path


def synthetic_dng(path):
    # Tiny uncompressed Bayer DNG: non-square default crop, rotated 90 degrees.
    width, height = 96, 80
    short = lambda n: struct.pack("<H", n)
    long = lambda n: struct.pack("<I", n)
    matrix = b"".join(struct.pack("<ii", int(i % 4 == 0), 1) for i in range(9))
    pixels = b"".join(short(1000 + 300 * x + 100 * y) for y in range(height) for x in range(width))
    fields = [(256, 4, 1, long(width)), (257, 4, 1, long(height)),
              (258, 3, 1, short(16)), (259, 3, 1, short(1)), (262, 3, 1, short(32803)),
              (273, 4, 1, long(0)), (274, 3, 1, short(6)), (277, 3, 1, short(1)),
              (278, 4, 1, long(height)), (279, 4, 1, long(len(pixels))),
              (284, 3, 1, short(1)), (33421, 3, 2, short(2) * 2),
              (33422, 1, 4, bytes((0, 1, 1, 2))), (50706, 1, 4, bytes((1, 4, 0, 0))),
              (50707, 1, 4, bytes((1, 1, 0, 0))), (50708, 2, 10, b"Synthetic\0"),
              (50717, 4, 1, long(65535)), (50719, 4, 2, long(8) * 2),
              (50720, 4, 2, long(80) + long(64)), (50721, 10, 9, matrix),
              (50728, 5, 3, struct.pack("<IIIIII", 1, 1, 1, 1, 1, 1)),
              (50778, 3, 1, short(21))]
    base = 14 + 12 * len(fields)
    overflow = bytearray()
    slots = []
    for tag, kind, count, value in fields:
        slots.append(value.ljust(4, b"\0") if len(value) <= 4 else long(base + len(overflow)))
        if len(value) > 4:
            overflow += value
            if len(overflow) % 2: overflow += b"\0"
    entries = bytearray()
    for (tag, kind, count, _), value in zip(fields, slots):
        entries += struct.pack("<HHI", tag, kind, count)
        entries += long(base + len(overflow)) if tag == 273 else value
    path.write_bytes(b"II" + struct.pack("<HIH", 42, 8, len(fields)) + entries + long(0) + overflow + pixels)


class EngineContract(unittest.TestCase):
    def setUp(self):
        self.engine = Handle()
        checked(LIB.hyperdr_engine_create, b"{}", ctypes.byref(self.engine))
        self.capabilities = json.loads(result(LIB.hyperdr_capabilities, self.engine))

    def tearDown(self):
        LIB.hyperdr_engine_destroy(self.engine)

    def assert_source_geometry(self, source, expected=None, half_size=False):
        probe = json.loads(result(LIB.hyperdr_probe, self.engine, os.fsencode(source)))
        dimensions = (probe["width"], probe["height"])
        if expected is not None:
            self.assertEqual(dimensions, expected)
        session = Handle()
        checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
        try:
            for compact in (False, True):
                request = {"preview_max_edge": 64, "command": {"compact": compact}}
                if half_size:
                    # half_size is internal/read-only in canonical settings;
                    # CLI --fast-preview explicitly selects that decode path.
                    with tempfile.TemporaryDirectory(prefix="hyperdr-fast-preview-") as temporary:
                        target = Path(temporary) / "preview.hpf"
                        arguments = [str(source), "--output", str(target),
                                     "--preview-max-edge", "64", "--fast-preview"]
                        if compact:
                            stream = subprocess.run([CLI, "preview-worker"],
                                input=encoded(arguments) + b"\n", capture_output=True, check=True).stdout
                            _, header, packet = stream.split(b"\n", 2)
                            self.assertEqual(len(packet), json.loads(header)["size"])
                        else:
                            subprocess.run([CLI, "preview-frame", *arguments], capture_output=True, check=True)
                            packet = target.read_bytes()
                else:
                    packet = self.packet(LIB.hyperdr_preview_render, session, request)
                length = struct.unpack_from("<I", packet, 8)[0]
                metadata = json.loads(packet[12:12 + length])
                self.assertEqual(packet[:8], b"HYPREV2\n" if compact else b"HYPREV1\n")
                self.assertEqual((metadata["sourceWidth"], metadata["sourceHeight"]), dimensions)
                self.assertLessEqual(max(metadata["width"], metadata["height"]), 64)
                if compact:
                    span = metadata["alternateHeadroom"] - metadata["baseHeadroom"]
                    weight = 0 if abs(span) < 1e-8 else max(0, min(1,
                        (metadata["headroomStops"] - metadata["baseHeadroom"]) / span))
                    self.assertAlmostEqual(metadata["gainWeight"], weight, places=5)
        finally:
            LIB.hyperdr_preview_close(session)

    def test_curve_with_frame_path_remains_pure(self):
        plain = result(LIB.hyperdr_curve_json, b"{}", 33)
        with_path = result(LIB.hyperdr_curve_json,
            encoded({"command": {"frame": "/missing/frame.json"}}), 33)
        self.assertEqual(plain, with_path)

    def test_missing_frame_overlay_names_path_before_decoding(self):
        with tempfile.TemporaryDirectory(prefix="hyperdr-missing-overlay-") as temporary:
            root = Path(temporary)
            directory = root / "directory.png"
            directory.mkdir()
            for overlay in (root / "caption.png", directory):
                with self.subTest(overlay=overlay.name):
                    spec = {"caption": 0.1, "overlay": overlay.name}
                    frame_file = root / "frame.json"
                    frame_file.write_text(json.dumps(spec))
                    output = root / "output"
                    source = root / "missing.jpg"
                    cli = subprocess.run([CLI, "convert", str(source), "--output", str(output),
                                          "--frame", str(frame_file)], capture_output=True)
                    self.assertEqual(cli.returncode, 2)
                    self.assertIn(b"frame: overlay", cli.stderr)
                    self.assertIn(os.fsencode(overlay), cli.stderr)
                    request = {"command": {"input": str(source), "output": str(output),
                                          "frame": str(frame_file)}}
                    value = ctypes.c_void_p()
                    error = ctypes.POINTER(Error)()
                    status = LIB.hyperdr_convert(self.engine, encoded(request), CALLBACK(), None,
                                                 None, ctypes.byref(value), ctypes.byref(error))
                    try:
                        self.assertNotEqual(status, 0)
                        self.assertFalse(value.value)
                        self.assertEqual(error.contents.code, b"invalid_options", error.contents.message)
                        self.assertIn(error.contents.message, cli.stderr)
                    finally:
                        LIB.hyperdr_string_free(value)
                        LIB.hyperdr_error_free(error)
                    self.assertFalse(output.exists())
                    # Synchronous geometry remains independent of filesystem state.
                    self.assertTrue(result(LIB.hyperdr_frame_layout,
                                           encoded({**spec, "overlay": str(overlay)}), 6000, 4000))

    def test_raw_and_heic_source_geometry_and_raw_metadata(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        source = raw_fixture("sony-ilce-7s-arw") # Required, never silently skipped.
        with tempfile.TemporaryDirectory(prefix="hyperdr-source-geometry-") as temporary:
            dng_path = Path(temporary) / "crop.dng"
            synthetic_dng(dng_path)
            for raw in (dng_path, source):
                with self.subTest(source=raw.name):
                    self.assert_source_geometry(raw, (64, 80) if raw == dng_path else None)
                    self.assert_source_geometry(raw, half_size=True)
                    expected = subprocess.check_output([CLI, "raw-metadata", str(raw)])
                    self.assertTrue(expected.endswith(b"\n"))
                    for _ in range(3):
                        self.assertEqual(result(LIB.hyperdr_raw_metadata, self.engine, os.fsencode(raw)), expected)
            fixtures = Path(__file__).resolve().parents[1] / "macos_t2/fixtures"
            heics = sorted(fixtures.glob("*.heic"))
            self.assertTrue(heics, "Required HEIC fixtures are missing")
            for heic in heics:
                with self.subTest(source=heic.name):
                    self.assert_source_geometry(heic)

    def test_invalid_resources_are_options_not_source_failures(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-resource-errors-") as temporary:
            root = Path(temporary)
            source, profile = root / "valid.dng", root / "valid.dcp"
            synthetic_dng(source)
            dcp(profile, camera_model="")
            session = Handle()
            checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
            try:
                # Establish that the photograph and the profile used by XMP
                # cases are valid; only the resource under test is broken.
                self.packet(LIB.hyperdr_preview_render, session,
                            {"command": {"_raw_profile_path": str(profile)}})
                for suffix, command_key, flag, diagnostic in [
                    ("dcp", "_raw_profile_path", "--raw-profile", b"DCP profile:"),
                    ("xmp", "_raw_look_path", "--raw-look", b"XMP look:"),
                    ("lcp", "_lens_profile_path", "--raw-lens-profile", b"LCP"),
                    ("cube", "_lut_path", "--lut", b"colour LUT")]:
                    for missing in (False, True):
                        with self.subTest(resource=suffix, missing=missing):
                            resource = root / (("missing." if missing else "broken.") + suffix)
                            if not missing:
                                resource.write_bytes(b"<broken" if suffix == "xmp" else b"broken")
                            command = {command_key: str(resource)}
                            arguments = [CLI, "preview-frame", str(source), "--output", str(root / "unused.hpf")]
                            if suffix == "xmp":
                                command["_raw_profile_path"] = str(profile)
                                arguments += ["--raw-profile", str(profile)]
                            arguments += [flag, str(resource)]
                            for frame_result in (False, True):
                                output = Frame() if frame_result else Buffer()
                                error = ctypes.POINTER(Error)()
                                function = LIB.hyperdr_preview_render_frame if frame_result else LIB.hyperdr_preview_render
                                try:
                                    status = function(session, encoded({"command": command}), None,
                                                      ctypes.byref(output), ctypes.byref(error))
                                    self.assertNotEqual(status, 0)
                                    self.assertEqual(error.contents.code, b"invalid_options", error.contents.message)
                                    self.assertFalse(output.owner)
                                    if not missing:
                                        self.assertIn(diagnostic, error.contents.message)
                                    cli = subprocess.run(arguments, capture_output=True)
                                    self.assertNotEqual(cli.returncode, 0)
                                    # Missing resources may be rejected earlier by
                                    # CLI option validation; malformed parsers keep
                                    # their exact diagnostic through both adapters.
                                    if not missing:
                                        self.assertIn(error.contents.message, cli.stderr)
                                finally:
                                    LIB.hyperdr_error_free(error)
                                    if frame_result:
                                        LIB.hyperdr_frame_free(ctypes.byref(output))
                                    else:
                                        LIB.hyperdr_buffer_free(ctypes.byref(output))
            finally:
                LIB.hyperdr_preview_close(session)

    def test_input_error_codes_preserve_cli_diagnostics(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-input-errors-") as temporary:
            root = Path(temporary)
            cases = [(root / "missing.jpg", "source_unreadable"),
                     (root / "unknown.xyz", "unsupported_format"),
                     (root / "corrupt.png", "decode_failed"),
                     (root / "corrupt.jpg", "decode_failed"),
                     (root / "corrupt.ARW", "decode_failed"),
                     (root / "missing.ARW", "source_unreadable")]
            for path, _ in cases:
                if not path.stem.startswith("missing"):
                    path.write_bytes(b"not an image")
            (root / "corrupt.png").write_bytes(b"\x89PNG\r\n\x1a\ntruncated")
            (root / "corrupt.jpg").write_bytes(b"\xff\xd8\xff\xe1\x00\x10truncated")
            unreadable = root / "unreadable.png"
            png(unreadable, 2, 2)
            unreadable.chmod(0)
            if os.access(unreadable, os.R_OK):
                self.fail("Permission-denied test requires an unprivileged test process")
            cases.append((unreadable, "source_unreadable"))
            try:
                for path, expected_code in cases:
                    with self.subTest(source=path.name):
                        output = ctypes.c_void_p(1)
                        error = ctypes.POINTER(Error)()
                        status = LIB.hyperdr_probe(self.engine, os.fsencode(path), ctypes.byref(output), ctypes.byref(error))
                        try:
                            self.assertNotEqual(status, 0)
                            self.assertIsNone(output.value)
                            self.assertEqual(error.contents.code.decode(), expected_code)
                            cli = subprocess.run([CLI, "probe", str(path)], capture_output=True)
                            self.assertNotEqual(cli.returncode, 0)
                            self.assertIn(error.contents.message, cli.stderr)
                        finally:
                            LIB.hyperdr_error_free(error)
                        session = Handle()
                        checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(path), None, ctypes.byref(session))
                        buffer, error = Buffer(), ctypes.POINTER(Error)()
                        try:
                            self.assertNotEqual(LIB.hyperdr_preview_render(session, b"{}", None, ctypes.byref(buffer), ctypes.byref(error)), 0)
                            self.assertEqual(error.contents.code.decode(), expected_code)
                            self.assertFalse(buffer.owner)
                        finally:
                            LIB.hyperdr_error_free(error)
                            LIB.hyperdr_buffer_free(ctypes.byref(buffer))
                            LIB.hyperdr_preview_close(session)
                for path in (root / "missing.ARW", root / "corrupt.ARW"):
                    output, error = ctypes.c_void_p(1), ctypes.POINTER(Error)()
                    status = LIB.hyperdr_raw_metadata(self.engine, os.fsencode(path), ctypes.byref(output), ctypes.byref(error))
                    try:
                        self.assertNotEqual(status, 0)
                        self.assertIsNone(output.value)
                        self.assertEqual(error.contents.code, b"source_unreadable" if path.stem == "missing" else b"decode_failed")
                    finally:
                        LIB.hyperdr_error_free(error)
            finally:
                unreadable.chmod(0o600)

    def test_python_goldens(self):
        for case in json.loads(Path(__file__).with_name("golden").joinpath("edit_options.json").read_text()):
            with self.subTest(options=case["options"]):
                if "error" in case:
                    with self.assertRaises(AssertionError):
                        normalized = result(LIB.hyperdr_normalize_options, encoded(case["options"]))
                        result(LIB.hyperdr_command_line, normalized)
                else:
                    normalized = result(LIB.hyperdr_normalize_options, encoded(case["options"]))
                    settings = json.loads(normalized)
                    self.assertEqual(settings.pop("command")["adapter"], "panel-v1")
                    self.assertEqual(settings, case["settings"])
                    self.assertEqual(json.loads(result(LIB.hyperdr_command_line, normalized)), case["argv"])

    def test_canonical_decimal_preview_and_exports_match_cli(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-canonical-decimals-") as temporary:
            root = Path(temporary)
            source = root / "sample.png"
            png(source, 128, 96)
            settings = {"contrast": 1.123456, "vibrance": -.234567,
                        "exposure_bias": .612345, "gain_strength": .456789,
                        "headroom": 2.345678, "expansion_start": .345678,
                        "area_coverage": .678912}
            flags = [item for key, value in settings.items()
                     for item in ("--" + key.replace("_", "-"), str(value))]
            session = Handle()
            checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None,
                    ctypes.byref(session))
            try:
                target = root / "preview.hpf"
                subprocess.run([CLI, "preview-frame", str(source), "--output", str(target),
                                *flags], capture_output=True, check=True)
                # Command metadata and the optional settings wrapper do not
                # turn a direct canonical request into a panel adapter request.
                for wrapped in (False, True):
                    request = {"settings": settings} if wrapped else dict(settings)
                    request["command"] = {"compact": False, "model_mode": False}
                    with self.subTest(wrapped=wrapped, operation="preview"):
                        self.assertEqual(self.packet(LIB.hyperdr_preview_render, session, request),
                                         target.read_bytes())
                    for encoding, extension in (("sdr-jpeg", "jpg"), ("ultrahdr", "jpg"),
                                                 ("avif-pq", "avif")):
                        with self.subTest(wrapped=wrapped, encoding=encoding):
                            destination, report_path = root / encoding, root / "report.json"
                            canonical = {**settings, "encoding": encoding}
                            export = {"settings": canonical} if wrapped else canonical
                            export["command"] = {"input": str(source), "output": str(destination),
                                                 "overwrite": True, "model_mode": False}
                            arguments = ["convert", str(source), "--output", str(destination),
                                         "--encoding", encoding, "--report", str(report_path), *flags]
                            report, cli_report = self.compare_export(export, arguments,
                                destination / ("sample-hyperdr." + extension), report_path)
                            self.assertEqual(report["settings"], cli_report["settings"])
            finally:
                LIB.hyperdr_preview_close(session)

    def test_canonical_ai_decimal_export_matches_cli(self):
        if not self.capabilities["codecs"] or not self.capabilities["models"]["runtimeAvailable"]:
            self.skipTest("requires codec-enabled build with native model runtime")
        with tempfile.TemporaryDirectory(prefix="hyperdr-canonical-ai-decimals-") as temporary:
            root = Path(temporary)
            source, destination, report_path = root / "sample.png", root / "export", root / "report.json"
            png(source, 128, 96)
            post = {"--ai-brightness": .123456, "--ai-contrast": 1.123456,
                    "--ai-shadows": -.234567, "--ai-highlights": .345678,
                    "--ai-hdr-range": 2.123456, "--ai-expansion-start": .345678}
            request = {"encoding": "ultrahdr", "gain_strength": .654321, "command": {
                "input": str(source), "output": str(destination),
                "model_id": "research-cnn-v1", "model_mode": True, "overwrite": True, **post}}
            flags = [item for key, value in post.items() for item in (key, str(value))]
            arguments = ["convert", str(source), "--output", str(destination),
                         "--encoding", "ultrahdr", "--report", str(report_path),
                         "--gain-strength", ".654321", "--ai-model", "research-cnn-v1", *flags]
            report, cli_report = self.compare_export(request, arguments,
                destination / "sample-hyperdr.jpg", report_path)
            self.assertEqual(report["settings"], cli_report["settings"])

    def test_unknown_adapter_is_rejected(self):
        for adapter in ("panel-v2", True):
            with self.subTest(adapter=adapter), self.assertRaisesRegex(
                    AssertionError, "unsupported edit options adapter"):
                result(LIB.hyperdr_curve_json, encoded({"contrast": 1.123456,
                       "command": {"adapter": adapter}}), 33)

    def compare_export(self, request, arguments, target, report_path):
        report = json.loads(result(LIB.hyperdr_convert, self.engine, encoded(request),
                                   CALLBACK(), None, None))
        self.assertEqual(len(report["files"]), 1)
        self.assertTrue(report["files"][0]["success"], report["files"][0]["message"])
        exported = target.read_bytes()
        # CTest preloads frozen_time.c into both processes, preserving the
        # original bytes including the ICC profile's creation timestamp.
        subprocess.run([CLI, *arguments, "--overwrite"], capture_output=True, check=True)
        self.assertEqual(exported, target.read_bytes())
        return report, json.loads(report_path.read_bytes())

    def test_command_profile_defaults_match_cli(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-profile-options-") as temporary:
            root = Path(temporary)
            source, profile = root / "sample.png", root / "camera.dcp"
            png(source, 128, 96)
            dcp(profile)
            # A raster isolates request/default handling from RAW development.
            # Test the two explicit flags independently, as the CLI does.
            for has_profile in (False, True):
                for contrast in (None, 1.19):
                    for vibrance in (None, .23):
                        with self.subTest(profile=has_profile, contrast=contrast, vibrance=vibrance):
                            destination, report_path = root / "export", root / "report.json"
                            request = {"encoding": "sdr-jpeg", "command": {
                                "input": str(source), "output": str(destination), "overwrite": True}}
                            arguments = ["convert", str(source), "--output", str(destination),
                                         "--encoding", "sdr-jpeg", "--report", str(report_path)]
                            if has_profile:
                                request["command"]["_raw_profile_path"] = str(profile)
                                arguments += ["--raw-profile", str(profile)]
                            for key, value in (("contrast", contrast), ("vibrance", vibrance)):
                                if value is not None:
                                    request[key] = value
                                    arguments += ["--" + key, str(value)]
                            report, cli_report = self.compare_export(request, arguments,
                                destination / "sample-hyperdr.jpg", report_path)
                            self.assertEqual(report["settings"], cli_report["settings"])
                            self.assertAlmostEqual(report["settings"]["contrast"],
                                contrast if contrast is not None else 1 if has_profile else 1.08)
                            self.assertAlmostEqual(report["settings"]["vibrance"],
                                vibrance if vibrance is not None else 0 if has_profile else .12)

    def test_normalized_decimal_exports_match_cli(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-decimal-options-") as temporary:
            root = Path(temporary)
            source, lut = root / "sample.png", root / "look.cube"
            png(source, 128, 96)
            lut.write_text("LUT_3D_SIZE 2\n" + "\n".join(
                f"{r * .9} {g * .8} {b * .7}" for b in range(2)
                for g in range(2) for r in range(2)) + "\n")
            cases = [
                {"brightness": .612345, "contrast": 1.123456},
                {"brightness": -.6125, "contrast": 1.2345, "vibrance": -.234567,
                 "hdrStrength": .456789, "hdrRange": 2.345678,
                 "expansionStart": .345678, "areaCoverage": .678912,
                 "lutStrength": .543219, "_lut_path": str(lut)},
            ]
            for controls in cases:
                for encoding, extension in (("sdr-jpeg", "jpg"), ("ultrahdr", "jpg"),
                                             ("avif-pq", "avif")):
                    with self.subTest(controls=controls, encoding=encoding):
                        destination, report_path = root / encoding, root / "report.json"
                        edit = {**controls, "encoding": encoding, "input": str(source),
                                "output": str(destination), "report": str(report_path)}
                        normalized = result(LIB.hyperdr_normalize_options, encoded(edit))
                        request = json.loads(normalized)
                        self.assertEqual(request["exposure_bias"], controls["brightness"])
                        self.assertEqual(request["contrast"], controls["contrast"])
                        arguments = json.loads(result(LIB.hyperdr_command_line, normalized))[1:]
                        self.assertEqual(arguments[arguments.index("--exposure-bias") + 1],
                                         ("%.3f" % controls["brightness"]).rstrip("0").rstrip("."))
                        self.assertEqual(arguments[arguments.index("--contrast") + 1],
                                         ("%.3f" % controls["contrast"]).rstrip("0").rstrip("."))
                        request["command"]["overwrite"] = True
                        report, cli_report = self.compare_export(request, arguments,
                            destination / ("sample-hyperdr." + extension), report_path)
                        self.assertEqual(report["settings"], cli_report["settings"])
                        self.assertEqual(report["color_lut"], cli_report["color_lut"])


    def test_frame_resources_are_one_snapshot_for_the_whole_batch(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        for mutation in ("spec", "file-overlay", "inline-overlay"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(prefix="hyperdr-frame-snapshot-") as temporary:
                root = Path(temporary)
                inputs = root / "inputs"
                inputs.mkdir()
                for name in ("first", "second"):
                    png(inputs / (name + ".png"), 128, 96)
                overlay = root / "caption.png"
                a = {"margins": .05}
                b = {"margins": .2}
                if mutation != "spec":
                    a.update(caption=.1, overlay=str(overlay))
                    layout = json.loads(result(LIB.hyperdr_frame_layout, encoded(a), 128, 96))
                    width, height = layout["caption"]["width"], layout["caption"]["height"]
                    png(overlay, width, height)
                    overlay_a = overlay.read_bytes()
                    # A valid, visibly different PNG of exactly the same size.
                    def chunk(kind, data):
                        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
                    overlay_b = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                        + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0" * width) * height)) + chunk(b"IEND", b""))
                frame = root / "frame.json"
                frame.write_text(json.dumps(a))
                request = json.loads(result(LIB.hyperdr_normalize_options, encoded({
                    "input": str(inputs), "output": str(root / "baseline"),
                    "report": str(root / "report.json"), "encoding": "sdr-jpeg"})))
                request["command"]["frame"] = a if mutation == "inline-overlay" else str(frame)

                def convert(callback=CALLBACK()):
                    report = json.loads(result(LIB.hyperdr_convert, self.engine, encoded(request), callback, None, None))
                    self.assertEqual(len(report["files"]), 2)
                    self.assertTrue(all(f["success"] for f in report["files"]), report)
                    return report["files"]

                def images(files):
                    return {Path(f["output"]).name: Path(f["output"]).read_bytes() for f in files}

                baseline = convert()
                expected = images(baseline)
                request["command"]["output"] = str(root / "race")
                events, errors = [], []
                phase = "decode" if mutation == "spec" else "process"
                def change_resource(_, message):
                    try:
                        if json.loads(message)["phase"] == phase:
                            events.append(phase)
                            if mutation == "spec":
                                frame.write_text(json.dumps(b))
                            else:
                                overlay.write_bytes(overlay_b)
                    except Exception as error:
                        errors.append(error)
                raced = convert(CALLBACK(change_resource))
                self.assertFalse(errors)
                self.assertEqual(len(events), 2)
                self.assertTrue(images(raced) == expected, "both batch files must use A's entry snapshot")
                self.assertTrue(all(f["frame"] == baseline[0]["frame"] for f in raced))
                frame.write_text(json.dumps(a))
                if mutation != "spec":
                    overlay.write_bytes(overlay_a)
                request["command"]["skip_existing"] = True
                resumed = convert()
                self.assertTrue(all(f["skipped"] for f in resumed))
                self.assertEqual(images(resumed), expected)
                if mutation != "inline-overlay":
                    arguments = json.loads(result(LIB.hyperdr_command_line, encoded(request)))[1:]
                    subprocess.run([CLI, *arguments, "--skip-existing"], capture_output=True, check=True)
                    cli_files = json.loads((root / "report.json").read_bytes())["files"]
                    self.assertTrue(all(f["skipped"] for f in cli_files))
                    self.assertEqual(images(cli_files), expected)
                # A new call must capture B, rather than retain the old snapshot.
                if mutation == "spec":
                    frame.write_text(json.dumps(b))
                else:
                    overlay.write_bytes(overlay_b)
                changed = convert()
                self.assertTrue(all(not f["skipped"] for f in changed))
                self.assertNotEqual(images(changed), expected)

    def test_frame_file_argv_parity_and_resume_content_identity(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-frame-file-") as temporary:
            root = Path(temporary)
            source, output, report_path = root / "sample.png", root / "output", root / "report.json"
            png(source, 128, 96)
            spec = {"margins": 0.05, "caption": 0.1, "overlay": "caption.png"}
            layout = json.loads(result(LIB.hyperdr_frame_layout, encoded(spec), 128, 96))
            overlay = root / "caption.png"
            png(overlay, layout["caption"]["width"], layout["caption"]["height"])
            frame_file = root / "边框 with spaces.json"
            frame_file.write_text(json.dumps(spec))
            request = json.loads(result(LIB.hyperdr_normalize_options, encoded({
                "input": str(source), "output": str(output), "report": str(report_path),
                "encoding": "sdr-jpeg"})))
            request["command"]["frame"] = str(frame_file)
            arguments = json.loads(result(LIB.hyperdr_command_line, encoded(request)))[1:]
            self.assertEqual(arguments[arguments.index("--frame") + 1], str(frame_file))
            report, cli_report = self.compare_export(request, arguments, output / "sample-hyperdr.jpg", report_path)
            self.assertEqual(report["schema"], 12)
            self.assertEqual(report["files"][0]["frame"]["width"], layout["width"])
            self.assertEqual(report["files"][0]["frame"], cli_report["files"][0]["frame"])
            def resume():
                subprocess.run([CLI, *arguments, "--skip-existing"], capture_output=True, check=True)
                return json.loads(report_path.read_bytes())["files"][0]
            self.assertTrue(resume()["skipped"])
            relocated = root / "relocated"
            relocated.mkdir()
            (relocated / "caption.png").write_bytes(overlay.read_bytes())
            other_spec = relocated / "frame.json"
            other_spec.write_text(json.dumps(spec, indent=2))
            arguments[arguments.index("--frame") + 1] = str(other_spec)
            self.assertTrue(resume()["skipped"], "equivalent content at another path must resume")
            target = output / "sample-hyperdr.jpg"
            before = target.read_bytes()
            # A valid PNG with identical dimensions but changed pixel values.
            data = (relocated / "caption.png").read_bytes()
            offset = data.index(b"IDAT")
            size = struct.unpack_from(">I", data, offset - 4)[0]
            rows = bytearray(zlib.decompress(data[offset + 4:offset + 4 + size]))
            stride = layout["caption"]["width"] * 3 + 1
            for row in range(layout["caption"]["height"]):
                for column in range(layout["caption"]["width"]):
                    rows[row * stride + 1 + column * 3] ^= 255
            payload = zlib.compress(rows)
            chunk = b"IDAT" + payload
            (relocated / "caption.png").write_bytes(data[:offset - 4] + struct.pack(">I", len(payload))
                + chunk + struct.pack(">I", zlib.crc32(chunk)) + data[offset + 8 + size:])
            self.assertFalse(resume()["skipped"], "changed overlay bytes must re-export")
            self.assertNotEqual(before, target.read_bytes())
            self.assertTrue(resume()["skipped"])
            spec["background"] = "#000000"
            other_spec.write_text(json.dumps(spec))
            self.assertFalse(resume()["skipped"], "changed frame content must re-export")

    def test_normalized_ai_decimal_export_matches_cli(self):
        if not self.capabilities["codecs"] or not self.capabilities["models"]["runtimeAvailable"]:
            self.skipTest("requires codec-enabled build with native model runtime")
        with tempfile.TemporaryDirectory(prefix="hyperdr-ai-decimal-options-") as temporary:
            root = Path(temporary)
            source, destination, report_path = root / "sample.png", root / "export", root / "report.json"
            png(source, 128, 96)
            edit = {"encoding": "ultrahdr", "input": str(source), "output": str(destination),
                    "report": str(report_path), "_model_mode": True, "_model_id": "research-cnn-v1",
                    "hdrStrength": .654321, "aiBrightness": .123456, "aiContrast": 1.123456,
                    "aiShadows": -.234567, "aiHighlights": .345678,
                    "aiHdrRange": 2.123456, "aiExpansionStart": .345678}
            normalized = result(LIB.hyperdr_normalize_options, encoded(edit))
            request = json.loads(normalized)
            self.assertEqual(request["command"]["--ai-brightness"], edit["aiBrightness"])
            arguments = json.loads(result(LIB.hyperdr_command_line, normalized))[1:]
            report, cli_report = self.compare_export(request, arguments,
                destination / "sample-hyperdr.jpg", report_path)
            self.assertEqual(report["settings"]["ai_post"], cli_report["settings"]["ai_post"])
            self.assertEqual(report["settings"]["gain_strength"], cli_report["settings"]["gain_strength"])

    def test_cancel_before_export(self):
        cancel = LIB.hyperdr_cancel_create()
        self.assertTrue(cancel)
        try:
            LIB.hyperdr_cancel_request(cancel)
            output = ctypes.c_void_p()
            error = ctypes.POINTER(Error)()
            start = time.perf_counter()
            self.assertNotEqual(LIB.hyperdr_convert(self.engine, b"{}", CALLBACK(), None, cancel,
                                                   ctypes.byref(output), ctypes.byref(error)), 0)
            try:
                self.assertEqual(error.contents.code, b"cancelled")
                self.assertFalse(output)
                self.assertLess(time.perf_counter() - start, .2)
            finally:
                LIB.hyperdr_error_free(error)
        finally:
            LIB.hyperdr_cancel_destroy(cancel)

    def packet(self, function, session, request):
        buffer = Buffer()
        checked(function, session, encoded(request), None, ctypes.byref(buffer))
        try:
            return ctypes.string_at(buffer.data, buffer.size)
        finally:
            LIB.hyperdr_buffer_free(ctypes.byref(buffer))
            self.assertFalse(buffer.owner)

    def test_images_and_frames(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-capi-") as temporary:
            root = Path(temporary)
            source = root / "sample.png"
            png(source, 128, 96)
            # Probe reports dimensions after applying EXIF orientation.
            subprocess.run([CLI, "convert", str(source), "--output", str(root/"oriented"), "--encoding", "sdr-jpeg"], capture_output=True, check=True)
            oriented = root/"oriented"/"sample-hyperdr.jpg"
            jpeg = oriented.read_bytes()
            exif = b"Exif\0\0II" + struct.pack("<HIH", 42, 8, 1) + struct.pack("<HHI", 0x112, 3, 1) + struct.pack("<HHI", 6, 0, 0)
            offset = 2
            while jpeg[offset:offset+1] == b"\xff" and jpeg[offset+1] not in (0xda, 0xd9):
                size = struct.unpack_from(">H", jpeg, offset+2)[0]
                if jpeg[offset:offset+2] == b"\xff\xe1" and jpeg[offset+4:offset+10] == b"Exif\0\0":
                    jpeg = jpeg[:offset] + jpeg[offset+2+size:]
                    continue
                offset += 2+size
            oriented.write_bytes(jpeg[:2]+b"\xff\xe1"+struct.pack(">H",len(exif)+2)+exif+jpeg[2:])
            oriented_probe = json.loads(result(LIB.hyperdr_probe, self.engine, os.fsencode(oriented)))
            self.assertEqual((oriented_probe["width"], oriented_probe["height"]), (96, 128))
            self.assert_source_geometry(oriented, (96, 128))
            session = Handle()
            checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
            try:
                probe = result(LIB.hyperdr_probe, self.engine, os.fsencode(source))
                self.assertEqual(probe, subprocess.check_output([CLI, "probe", str(source), "--json"]))
                self.assertEqual((json.loads(probe)["width"], json.loads(probe)["height"]), (128, 96))
                # Normal CLI file packets remain v1; the worker and new ABI
                # default to compact v2. Test both existing transport contracts.
                for compact in (False, True):
                    request = {"command": {"compact": compact}}
                    packet = self.packet(LIB.hyperdr_preview_render, session, request)
                    if compact:
                        worker = subprocess.run([CLI, "preview-worker"],
                            input=encoded([str(source), "--output", str(root / "unused.hpf")]) + b"\n",
                            capture_output=True, check=True).stdout
                        _, header, reference = worker.split(b"\n", 2)
                        self.assertEqual(len(reference), json.loads(header)["size"])
                    else:
                        target = root / "preview.hpf"
                        subprocess.run([CLI, "preview-frame", str(source), "--output", str(target)], check=True)
                        reference = target.read_bytes()
                    self.assertEqual(packet, reference)
                    frame = Frame()
                    checked(LIB.hyperdr_preview_render_frame, session, encoded(request), None, ctypes.byref(frame))
                    try:
                        length = struct.unpack_from("<I", packet, 8)[0]
                        self.assertEqual(frame.metadata_json, packet[12:12+length])
                        offset = 12 + length
                        for plane in (frame.base, frame.gain):
                            self.assertEqual(plane.data % os.sysconf("SC_PAGE_SIZE"), 0)
                            self.assertEqual(plane.size % os.sysconf("SC_PAGE_SIZE"), 0)
                            self.assertEqual(plane.format, 1)
                            used = plane.row_bytes * plane.height
                            self.assertEqual(ctypes.string_at(plane.data, used), packet[offset:offset+used])
                            self.assertEqual(ctypes.string_at(plane.data+used, plane.size-used), b"\0"*(plane.size-used))
                            offset += used
                        self.assertEqual(offset, len(packet))
                    finally:
                        LIB.hyperdr_frame_free(ctypes.byref(frame))
                        self.assertFalse(frame.owner)
                for encoding, extension in [("sdr-jpeg", "jpg"), ("sdr-tiff", "tif"),
                        ("ultrahdr", "jpg"), ("avif-pq", "avif"), ("avif-hlg", "avif")]:
                    destination = root / encoding
                    target = destination / ("sample-hyperdr." + extension)
                    request = {"encoding": encoding, "command": {"input": str(source), "output": str(destination), "overwrite": True}}
                    events = []
                    callback = CALLBACK(lambda _, event: events.append(json.loads(event)))
                    report = json.loads(result(LIB.hyperdr_convert, self.engine, encoded(request), callback, None, None))
                    exported = target.read_bytes()
                    cli = subprocess.run([CLI, "convert", str(source), "--output", str(destination), "--encoding", encoding, "--overwrite"], capture_output=True, check=True)
                    self.assertEqual(exported, target.read_bytes(), encoding)
                    self.assertEqual("".join(e["text"] for e in events).encode(), cli.stderr)
                    self.assertEqual(events[0]["phase"], "decode")
                    self.assertEqual(events[-1]["phase"], "complete")
                    # Presentation-frame geometry extends the report to schema 12.
                    self.assertEqual(report["schema"], 12)
                models = json.loads(subprocess.check_output([CLI, "model-list", "--json"]))
                # Core-only ncnn is intentionally absent. The model table owns
                # availability; no second registry is maintained by this test.
                if models["runtimeAvailable"]:
                    request = {"command": {"model_id": "research-cnn-v1"}}
                    packet = self.packet(LIB.hyperdr_model_gain, session, request)
                    self.assertEqual(packet, subprocess.check_output([CLI, "model-gain", str(source), "--ai-model", "research-cnn-v1"]))
            finally:
                LIB.hyperdr_preview_close(session)

    def test_cancel_active_render_and_export(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-cancel-") as temporary:
            root = Path(temporary)
            source = root / "large.png"
            # Build an inexpensive, highly compressible 8 MP fixture. Render
            # from a warm session so timing measures cancellation during work.
            width, height = 3264, 2448
            def chunk(kind, data):
                return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data))
            source.write_bytes(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",width,height,8,2,0,0,0))
                +chunk(b"IDAT",zlib.compress((b"\0"+b"\x60\x90\xb0"*width)*height))+chunk(b"IEND",b""))
            session = Handle()
            checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
            try:
                self.packet(LIB.hyperdr_preview_render, session, {"preview_max_edge": 4096})
                for operation in ("render", "export"):
                    cancel = LIB.hyperdr_cancel_create()
                    error = ctypes.POINTER(Error)()
                    buffer = Buffer()
                    output = ctypes.c_void_p()
                    status = []
                    started = threading.Event()
                    def work():
                        started.set()
                        if operation == "render":
                            status.append(LIB.hyperdr_preview_render(session, encoded({"contrast":1.2,"preview_max_edge":4096}), cancel, ctypes.byref(buffer), ctypes.byref(error)))
                        else:
                            req = {"encoding":"sdr-jpeg", "command":{"input":str(source),"output":str(root/"export")}}
                            status.append(LIB.hyperdr_convert(self.engine, encoded(req), CALLBACK(), None, cancel, ctypes.byref(output), ctypes.byref(error)))
                    thread = threading.Thread(target=work)
                    thread.start(); started.wait(); time.sleep(.01)
                    if operation == "render":
                        busy_buffer, busy_error = Buffer(), ctypes.POINTER(Error)()
                        busy_status = LIB.hyperdr_preview_render(session, b"{}", None, ctypes.byref(busy_buffer), ctypes.byref(busy_error))
                        try:
                            self.assertNotEqual(busy_status, 0)
                            self.assertEqual(busy_error.contents.code, b"busy")
                        finally:
                            LIB.hyperdr_error_free(busy_error)
                            LIB.hyperdr_buffer_free(ctypes.byref(busy_buffer))
                    begin = time.perf_counter(); LIB.hyperdr_cancel_request(cancel)
                    thread.join()
                    elapsed = time.perf_counter()-begin
                    try:
                        self.assertFalse(thread.is_alive())
                        self.assertNotEqual(status, [0])
                        self.assertEqual(error.contents.code, b"cancelled")
                        self.assertLess(elapsed, .2, operation)
                        self.assertFalse(list((root/"export").glob("*.jpg")))
                        print(f"{operation} cancel: {elapsed*1000:.2f} ms", flush=True)
                    finally:
                        LIB.hyperdr_error_free(error); LIB.hyperdr_buffer_free(ctypes.byref(buffer))
                        LIB.hyperdr_string_free(output); LIB.hyperdr_cancel_destroy(cancel)
            finally:
                LIB.hyperdr_preview_close(session)

if __name__ == "__main__":
    unittest.main()
