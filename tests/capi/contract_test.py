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
# dlsym on the library handle also searches its dependencies, so a library
# built with ASan or UBSan exposes the runtime's entry points.
SANITIZED = any(hasattr(LIB, name) for name in ("__asan_init", "__ubsan_handle_add_overflow"))
# Encode-stage cancellation must finish within 200 ms; sanitizer builds run
# the same loops several times slower.
ENCODE_CANCEL_LIMIT = 1.0 if SANITIZED else .2


class Error(ctypes.Structure):
    _fields_ = [("code", ctypes.c_char_p), ("message", ctypes.c_char_p), ("detail_json",ctypes.c_char_p)]


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
    def test_frame_variant_invalid_documents(self):
        invalid = [
            {"wide": {}}, {"wide": {"minRatio": 2.5, "maxRatio": 0.125}},
            {"wide": {"minRatio": 1}}, {"tall": {"maxRatio": 1}},
            {"a": {"minRatio": 2}, "b": {"minRatio": 3}},
            {"a": {"maxRatio": 0.1}, "b": {"maxRatio": 0.2}},
            {"Wide": {"minRatio": 2}}, {"": {"minRatio": 2}},
            {"a" * 33: {"minRatio": 2}}, {str(i): {"minRatio": 2} for i in range(5)},
        ]
        invalid += [{"wide": {"minRatio": 2.5, key: None}} for key in
                    ("background", "shadow", "overlay", "schema", "variants")]
        with tempfile.TemporaryDirectory(prefix="hyperdr-invalid-variants-") as temporary:
            path = Path(temporary) / "frame.json"
            for variants in invalid:
                with self.subTest(variants=variants):
                    spec = {"variants": variants}
                    path.write_text(json.dumps(spec))
                    cli = subprocess.run([CLI, "frame-layout", str(path), "--width", "4000", "--height", "1000"], capture_output=True)
                    self.assertEqual(cli.returncode, 2)
                    self.assertIn(b"frame:", cli.stderr)
                    with self.assertRaisesRegex(AssertionError, "frame:"):
                        result(LIB.hyperdr_frame_layout, encoded(spec), 4000, 1000)

    def test_frame_variant_design_goldens(self):
        golden = json.loads((Path(__file__).parent / "golden/frame_variants.json").read_text())
        with tempfile.TemporaryDirectory(prefix="hyperdr-frame-variants-") as temporary:
            path = Path(temporary) / "frame.json"
            for case in golden["cases"]:
                spec = json.loads(json.dumps(golden["spec"]))
                if case["noCaption"]:
                    spec["caption"] = 0
                    for variant in spec["variants"].values():
                        if "caption" in variant:
                            variant["caption"] = 0
                path.write_text(json.dumps(spec))
                expected = case["expected"].encode()
                self.assertEqual(result(LIB.hyperdr_frame_layout, encoded(spec), case["width"], case["height"]), expected)
                self.assertEqual(subprocess.check_output([CLI, "frame-layout", str(path),
                    "--width", str(case["width"]), "--height", str(case["height"])]), expected)

    def test_frame_variant_thresholds_use_double_value_semantics(self):
        cases = [("wide", "minRatio", "2.5999999999999999", "2.6", 2600, 1000),
                 ("tall", "maxRatio", "0.12500000000000001", "0.125", 1000, 8000)]
        with tempfile.TemporaryDirectory(prefix="hyperdr-double-ratio-") as temporary:
            path = Path(temporary) / "frame.json"
            for name, key, literal, rounded, boundary, height in cases:
                for width in (boundary - 1, boundary, boundary + 1):
                    with self.subTest(name=name, width=width):
                        outputs = []
                        for threshold in (literal, rounded):
                            # Preserve the raw numeric token for both adapters.
                            document = '{"variants":{"%s":{"%s":%s}}}' % (name, key, threshold)
                            abi = result(LIB.hyperdr_frame_layout, document.encode(), width, height)
                            path.write_text(document)
                            cli = subprocess.check_output([CLI, "frame-layout", str(path),
                                "--width", str(width), "--height", str(height)])
                            self.assertEqual(abi, cli)
                            outputs.append(abi)
                        self.assertEqual(outputs[0], outputs[1])
                        selected = width > boundary if name == "wide" else width < boundary
                        self.assertEqual(json.loads(outputs[0]).get("variant"), name if selected else None)

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
                                   ({"raw_gain": 2.0}, 65)]:
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


def synthetic_dng(path, focal_length=False):
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
    if focal_length:
        fields.append((37386, 5, 1, struct.pack("<II", 35, 1)))
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

    def test_capabilities_cli_and_overrides(self):
        for override in (None, "unavailable", "no-main10"):
            handle = Handle()
            config = {} if override is None else {"hevc_override": override}
            checked(LIB.hyperdr_engine_create, encoded(config), ctypes.byref(handle))
            try:
                env = dict(os.environ)
                env.pop("HYPERDR_TEST_HEVC", None)
                if override:
                    env["HYPERDR_TEST_HEVC"] = override
                document = result(LIB.hyperdr_capabilities, handle)
                self.assertEqual(document, subprocess.check_output([CLI, "capabilities", "--json"], env=env))
                self.assertEqual(document, subprocess.check_output([CLI, "capabilities"], env=env))
                caps = json.loads(document)
                encoder = caps["encoder"]
                self.assertEqual(encoder["backend"], "videotoolbox")
                if caps["codecs"]:
                    self.assertEqual(encoder["main8"], override != "unavailable")
                    self.assertEqual(encoder["main10"], override is None)
                    self.assertEqual(encoder["state"], "unavailable" if override == "unavailable" else "ready")
                    self.assertEqual(encoder["reason"], {None: "", "unavailable": "hevc_unavailable",
                                     "no-main10": "hevc_main10_unavailable"}[override])
                    for encoding in caps["encodings"]:
                        hevc = encoding["id"] in ("adaptive", "pq", "hlg")
                        blocked = hevc and (override == "unavailable" or
                                  (override == "no-main10" and encoding["id"] != "adaptive"))
                        self.assertEqual(encoding["available"], not blocked)
                        self.assertEqual(encoding["reason"], encoder["reason"] if blocked else "")
            finally:
                LIB.hyperdr_engine_destroy(handle)
        # A CLI-only environment override must not leak into the ABI engine.
        previous = os.environ.get("HYPERDR_TEST_HEVC")
        try:
            os.environ["HYPERDR_TEST_HEVC"] = "unavailable"
            self.assertEqual(json.loads(result(LIB.hyperdr_capabilities, self.engine)), self.capabilities)
        finally:
            if previous is None:
                os.environ.pop("HYPERDR_TEST_HEVC", None)
            else:
                os.environ["HYPERDR_TEST_HEVC"] = previous

    def test_hevc_export_override_failures_and_non_hevc(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-v4-") as temporary:
            root = Path(temporary)
            source = root / "source.png"
            png(source, 64, 48)
            for override in ("unavailable", "no-main10"):
                handle = Handle()
                checked(LIB.hyperdr_engine_create, encoded({"hevc_override": override}), ctypes.byref(handle))
                try:
                    for encoding, depth in (("adaptive", 8), ("adaptive", 10), ("pq", 10), ("hlg", 10),
                                            ("sdr-jpeg", 8), ("sdr-tiff", 8), ("iso-gainmap-jpeg", 8),
                                            ("avif-pq", 10), ("avif-hlg", 10)):
                        with self.subTest(override=override, encoding=encoding, depth=depth):
                            destination = root / (override + encoding + str(depth))
                            report_path = root / "report.json"
                            request = {"encoding": encoding, "command": {"input": str(source),
                                       "output": str(destination), "depth": depth, "overwrite": True}}
                            document = json.loads(result(LIB.hyperdr_convert, handle, encoded(request), CALLBACK(), None, None))
                            file = document["files"][0]
                            hevc = encoding in ("adaptive", "pq", "hlg")
                            blocked = hevc and (override == "unavailable" or depth == 10)
                            self.assertEqual(document["schema"], 13)
                            self.assertEqual(file["success"], not blocked, file)
                            target = Path(file["output"])
                            self.assertEqual(target.exists(), not blocked)
                            expected = None
                            if not blocked:
                                expected = target.read_bytes()
                                target.unlink()
                            else:
                                self.assertEqual(file["error_code"], "hevc_unavailable" if override == "unavailable"
                                                 else "hevc_main10_unavailable")
                            cli = subprocess.run([CLI, "convert", str(source), "--output", str(destination),
                                "--encoding", encoding, "--depth", str(depth), "--report", str(report_path)],
                                env=dict(os.environ, HYPERDR_TEST_HEVC=override), capture_output=True)
                            self.assertEqual(cli.returncode, 1 if blocked else 0, cli.stderr)
                            cli_file = json.loads(report_path.read_bytes())["files"][0]
                            self.assertEqual(cli_file["success"], file["success"])
                            if blocked:
                                self.assertEqual(cli_file["error_code"], file["error_code"])
                                self.assertFalse(target.exists())
                                self.assertEqual(list(destination.iterdir()), [])
                            else:
                                self.assertEqual(target.read_bytes(), expected)
                finally:
                    LIB.hyperdr_engine_destroy(handle)

    def test_hevc_resume_hit_exempts_gate_but_new_file_fails(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-v4-resume-") as temporary:
            for encoding in ("adaptive", "pq", "hlg"):
                for interface in ("cli", "abi"):
                    with self.subTest(encoding=encoding, interface=interface):
                        root = Path(temporary) / encoding / interface
                        sources, destination = root / "inputs", root / "out"
                        sources.mkdir(parents=True)
                        first, second = sources / "first.png", sources / "second.png"
                        png(first, 64, 48)
                        report_path = root / "report.json"
                        request = {"encoding": encoding, "command": {"input": str(sources),
                            "output": str(destination), "depth": 10, "overwrite": True, "skip_existing": True}}
                        arguments = [CLI, "convert", str(sources), "--output", str(destination),
                            "--encoding", encoding, "--depth", "10", "--overwrite", "--skip-existing",
                            "--report", str(report_path)]
                        env = dict(os.environ)
                        env.pop("HYPERDR_TEST_HEVC", None)
                        if interface == "cli":
                            subprocess.run(arguments, env=env, capture_output=True, check=True)
                            seeded = json.loads(report_path.read_bytes())
                        else:
                            seeded = json.loads(result(LIB.hyperdr_convert, self.engine,
                                encoded(request), CALLBACK(), None, None))
                        self.assertEqual(len(seeded["files"]), 1)
                        existing = seeded["files"][0]
                        self.assertTrue(existing["success"], existing)
                        self.assertFalse(existing["skipped"])
                        target = Path(existing["output"])
                        digest = hashlib.sha256(target.read_bytes()).hexdigest()
                        # The second source has no output when this same batch resumes.
                        png(second, 63, 47)
                        if interface == "cli":
                            replay = subprocess.run(arguments,
                                env=dict(env, HYPERDR_TEST_HEVC="no-main10"), capture_output=True)
                            self.assertEqual(replay.returncode, 1, replay.stderr)
                            document = json.loads(report_path.read_bytes())
                        else:
                            handle = Handle()
                            checked(LIB.hyperdr_engine_create, encoded({"hevc_override": "no-main10"}),
                                    ctypes.byref(handle))
                            try:
                                document = json.loads(result(LIB.hyperdr_convert, handle,
                                    encoded(request), CALLBACK(), None, None))
                            finally:
                                LIB.hyperdr_engine_destroy(handle)
                        self.assertEqual(document["schema"], 13)
                        self.assertEqual(len(document["files"]), 2)
                        files = {Path(file["input"]).name: file for file in document["files"]}
                        skipped, failed = files[first.name], files[second.name]
                        self.assertTrue(skipped["success"], skipped)
                        self.assertTrue(skipped["skipped"], skipped)
                        self.assertNotIn("error_code", skipped)
                        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), digest)
                        self.assertFalse(failed["success"], failed)
                        self.assertFalse(failed["skipped"], failed)
                        self.assertEqual(failed["error_code"], "hevc_main10_unavailable")
                        self.assertFalse(Path(failed["output"]).exists())

    def assert_source_geometry(self, source, expected=None, fast_preview=False):
        probe = json.loads(result(LIB.hyperdr_probe, self.engine, os.fsencode(source)))
        dimensions = (probe["width"], probe["height"])
        if expected is not None:
            self.assertEqual(dimensions, expected)
        session = Handle()
        checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
        try:
            for compact in (False, True):
                request = {"preview_max_edge": 64, "command": {"compact": compact}}
                if fast_preview:
                    # CLI --fast-preview selects preview intent; RAW scale follows
                    # the requested edge rather than a fixed demosaic ratio.
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
            for raw in (source, raw_fixture("canon-5d-iii-lossy-dng"), raw_fixture("leica-c-portrait-rwl")):
                with self.subTest(source=raw.name):
                    self.assert_source_geometry(raw, (64, 80) if raw == dng_path else None)
                    self.assert_source_geometry(raw, fast_preview=True)
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

    def test_raw_lens_correction_adapter_and_cli_flag(self):
        request=result(LIB.hyperdr_normalize_options,encoded({"input":"/fixture.raw","output":"/out","report":"/report.json","lensCorrection":False}))
        self.assertFalse(json.loads(request)["raw_lens_correction"])
        self.assertIn("--no-raw-lens-correction",json.loads(result(LIB.hyperdr_command_line,request)))
        default=json.loads(result(LIB.hyperdr_normalize_options,b"{}"))
        self.assertTrue(default["raw_lens_correction"])

    def test_apple_raw_cli_abi_and_repeated_processes(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codecs")
        golden=json.loads((Path(__file__).parent/"golden/raw_ciraw.json").read_text())
        for ident in ("sony-ilce-7s-arw","canon-5d-iii-lossy-dng","leica-c-portrait-rwl"):
            source=raw_fixture(ident)
            with self.subTest(fixture=ident),tempfile.TemporaryDirectory(prefix="hyperdr-apple-raw-") as temporary:
                root=Path(temporary);destination=root/"out";report_path=root/"report.json"
                probe=result(LIB.hyperdr_probe,self.engine,os.fsencode(source))
                self.assertEqual(probe,subprocess.check_output([CLI,"probe",str(source)]))
                session=Handle()
                checked(LIB.hyperdr_preview_open,self.engine,os.fsencode(source),None,ctypes.byref(session))
                try:
                    request={"preview_max_edge":64,"command":{"compact":False}}
                    packet=self.packet(LIB.hyperdr_preview_render,session,request)
                    target=root/"preview.hpf"
                    subprocess.run([CLI,"preview-frame",str(source),"--preview-max-edge","64","--output",str(target)],capture_output=True,check=True)
                    self.assertEqual(packet,target.read_bytes())
                    self.assertEqual(packet,self.packet(LIB.hyperdr_preview_render,session,request))
                    length=struct.unpack_from("<I",packet,8)[0]
                    metadata=json.loads(packet[12:12+length])
                    self.assertEqual(metadata["raw"],json.loads(probe)["raw"])
                    self.assertEqual(hashlib.sha256(packet).hexdigest(),golden["cases"][ident]["preview_sha256"])
                finally:
                    LIB.hyperdr_preview_close(session)
                request={"encoding":"iso-gainmap-jpeg","command":{"input":str(source),"output":str(destination),"overwrite":True}}
                report,_=self.compare_export(request,["convert",str(source),"--output",str(destination),"--encoding","iso-gainmap-jpeg","--report",str(report_path)],destination/(source.stem+"-hyperdr.jpg"),report_path)
                self.assertEqual(report["files"][0]["raw_processing"]["engine"],"apple-ciraw")
                self.assertEqual(report["files"][0]["raw_processing"]["decoder_version"],json.loads(probe)["raw"]["decoderVersion"])
                self.assertEqual(report["files"][0]["raw_processing"]["os_build"],json.loads(probe)["raw"]["osBuild"])
                self.assertEqual(hashlib.sha256((destination/(source.stem+"-hyperdr.jpg")).read_bytes()).hexdigest(),golden["cases"][ident]["export_sha256"])

    def test_synthetic_dng_is_unsupported_by_system(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-unsupported-raw-") as temporary:
            source=Path(temporary)/"unsupported.dng"
            synthetic_dng(source)
            renamed=source.with_suffix(".ARW")
            renamed.write_bytes(source.read_bytes())
            expected={"container":"dng","model":""}
            for path in (source,renamed):
                for function in (LIB.hyperdr_probe,LIB.hyperdr_raw_metadata):
                    output,error=ctypes.c_void_p(),ctypes.POINTER(Error)()
                    try:
                        self.assertNotEqual(function(self.engine,os.fsencode(path),ctypes.byref(output),ctypes.byref(error)),0)
                        self.assertIsNone(output.value)
                        self.assertEqual(error.contents.code,b"raw_unsupported")
                        self.assertEqual(json.loads(error.contents.detail_json),expected)
                        message=error.contents.message
                    finally:
                        LIB.hyperdr_error_free(error)
                        LIB.hyperdr_string_free(output)
                session=Handle()
                checked(LIB.hyperdr_preview_open,self.engine,os.fsencode(path),None,ctypes.byref(session))
                try:
                    for function in (LIB.hyperdr_preview_render,LIB.hyperdr_model_gain):
                        buffer,error=Buffer(),ctypes.POINTER(Error)()
                        try:
                            self.assertNotEqual(function(session,encoded({"command":{"model_id":"research-cnn-v1"}}),None,ctypes.byref(buffer),ctypes.byref(error)),0)
                            self.assertEqual(error.contents.code,b"raw_unsupported")
                            self.assertEqual(json.loads(error.contents.detail_json),expected)
                            self.assertFalse(buffer.owner)
                        finally:
                            LIB.hyperdr_error_free(error)
                            LIB.hyperdr_buffer_free(ctypes.byref(buffer))
                finally:
                    LIB.hyperdr_preview_close(session)
                cli=subprocess.run([CLI,"probe",str(path)],capture_output=True)
                self.assertNotEqual(cli.returncode,0)
                self.assertIn(message,cli.stderr)
                self.assertNotIn(b'"container"',cli.stderr)
                request={"command":{"input":str(path),"output":str(Path(temporary)/"out"),"overwrite":True}}
                output,error=ctypes.c_void_p(),ctypes.POINTER(Error)()
                try:
                    # Conversion returns a report even when the file fails.
                    LIB.hyperdr_convert(self.engine,encoded(request),CALLBACK(),None,None,ctypes.byref(output),ctypes.byref(error))
                    self.assertFalse(error)
                    report=json.loads(ctypes.string_at(output))
                    file=report["files"][0]
                    self.assertEqual(file["error_code"],"raw_unsupported")
                    self.assertEqual(file["error_detail"],expected)
                    self.assertEqual(file["detail"].encode(),message)
                finally:
                    LIB.hyperdr_error_free(error)
                    LIB.hyperdr_string_free(output)

    def test_invalid_resources_are_options_not_source_failures(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-resource-errors-") as temporary:
            root = Path(temporary)
            source, profile = root / "valid.dng", root / "valid.dcp"
            source=raw_fixture("sony-ilce-7s-arw")
            dcp(profile, camera_model="")
            session = Handle()
            checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
            try:
                # Establish that the photograph and the profile used by XMP
                # cases are valid; only the resource under test is broken.
                self.packet(LIB.hyperdr_preview_render, session, {})
                for suffix, command_key, flag, diagnostic in [
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
                     (root / "corrupt.ARW", "raw_unsupported"),
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
                        self.assertEqual(error.contents.code, b"source_unreadable" if path.stem == "missing" else b"raw_unsupported")
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
                    # The frozen Python output still says `ultrahdr`; the engine
                    # writes the canonical name (U12).
                    expected = dict(case["settings"])
                    # R2 intentionally diverges from the frozen Web adapter.
                    expected.pop("highlight_recovery", None)
                    expected["raw_lens_correction"]=case["options"].get("lensCorrection", True)
                    if expected["encoding"] == "ultrahdr":
                        expected["encoding"] = "iso-gainmap-jpeg"
                    argv = ["iso-gainmap-jpeg" if previous == "--encoding" and item == "ultrahdr" else item
                            for previous, item in zip([None, *case["argv"]], case["argv"])]
                    removed = {"--highlight-recovery", "--raw-profile", "--raw-look", "--raw-lens-profile"}
                    filtered = []
                    index = 0
                    while index < len(argv):
                        if argv[index] in removed:
                            index += 2
                        else:
                            filtered.append(argv[index])
                            index += 1
                    argv = filtered
                    self.assertEqual(settings, expected)
                    self.assertEqual(json.loads(result(LIB.hyperdr_command_line, normalized)), argv)

    def test_removed_raw_options_and_ignored_highlight_control(self):
        # Deleted controls cannot reach an engine entry through canonical
        # settings or private routing. Obsolete highlight values are inert.
        for key in ("raw_profile", "raw_look", "raw_lens_profile", "raw_auto_bad_pixels", "half_size"):
            with self.subTest(key=key):
                with self.assertRaises(AssertionError):
                    result(LIB.hyperdr_curve_json, encoded({key: "obsolete"}), 33)
        for key in ("_raw_profile_path", "_raw_look_path", "_lens_profile_path"):
            with self.assertRaises(AssertionError):
                result(LIB.hyperdr_command_line, encoded({"command": {key: "obsolete"}}))
        for flag in ("--raw-profile", "--raw-look", "--raw-lens-profile", "--raw-auto-bad-pixels",
                     "--raw-bad-pixels", "--raw-dark-frame", "--raw-linearization-lut", "--raw-lens-shading",
                     "--highlight-recovery"):
            rejected = subprocess.run([CLI, "curve", flag, "obsolete"], capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"unknown", rejected.stderr)
        for command in ("thumbnail", "model-input"):
            rejected = subprocess.run([CLI, command, "unused.ARW", "--half-size"], capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"unknown", rejected.stderr)
        expected = result(LIB.hyperdr_curve_json, b"{}", 33)
        for key in ("highlight_recovery", "highlightRecovery"):
            for value in ("clip", "invalid", 42, None, {"old": True}):
                self.assertEqual(result(LIB.hyperdr_curve_json, encoded({key: value}), 33), expected)
        normalized = result(LIB.hyperdr_normalize_options, b"{}")
        self.assertEqual(result(LIB.hyperdr_normalize_options, encoded({"highlightRecovery": {"old": True}})), normalized)

    def test_ultrahdr_is_an_alias_until_p2c(self):
        def normalize(options):
            return result(LIB.hyperdr_normalize_options, encoded(options))
        base = {"input": "/fixtures/source.jpg", "output": "/exports", "report": "/exports/report.json"}
        canonical = normalize({**base, "encoding": "iso-gainmap-jpeg"})
        self.assertEqual(normalize({**base, "encoding": "ultrahdr"}), canonical)
        self.assertEqual(json.loads(canonical)["encoding"], "iso-gainmap-jpeg")
        self.assertEqual(json.loads(canonical)["command"]["depth"], 8)
        argv = json.loads(result(LIB.hyperdr_command_line, canonical))
        self.assertEqual(argv[argv.index("--encoding") + 1], "iso-gainmap-jpeg")
        self.assertNotIn(b"ultrahdr", result(LIB.hyperdr_schema_json))
        for removed in ("gain-map", "ultra-hdr", "jpegr", "avif", "sdr", "tiff"):
            with self.subTest(removed=removed):
                with self.assertRaises(AssertionError):
                    normalize({**base, "encoding": removed})
                rejected = subprocess.run([CLI, "convert", "missing.png", "--output", "/nonexistent",
                                           "--encoding", removed], capture_output=True)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(b"encoding", rejected.stderr)
        if not self.capabilities["codecs"]:
            return
        with tempfile.TemporaryDirectory(prefix="hyperdr-encoding-alias-") as temporary:
            root = Path(temporary)
            source = root / "sample.png"
            png(source, 64, 48)
            outputs = {}
            for name in ("iso-gainmap-jpeg", "ultrahdr"):
                destination, report_path = root / name, root / (name + ".json")
                request = {"encoding": name, "command": {
                    "input": str(source), "output": str(destination), "overwrite": True}}
                report, _ = self.compare_export(request,
                    ["convert", str(source), "--output", str(destination), "--encoding", name,
                     "--report", str(report_path)], destination / "sample-hyperdr.jpg", report_path)
                self.assertEqual(report["settings"]["encoding"], "iso-gainmap-jpeg")
                outputs[name] = (destination / "sample-hyperdr.jpg").read_bytes()
            self.assertEqual(outputs["iso-gainmap-jpeg"], outputs["ultrahdr"])
            verified = subprocess.run([CLI, "verify", str(root / "ultrahdr" / "sample-hyperdr.jpg")],
                                      capture_output=True, text=True, check=True)
            self.assertIn("ISO gain-map JPEG: yes", verified.stdout)
            # A gain map described only in `hdrgm` XMP is not what this
            # encoding writes, so verify refuses it instead of passing it as SDR.
            sdr = root / "sdr"
            subprocess.run([CLI, "convert", str(source), "--output", str(sdr), "--encoding", "sdr-jpeg"],
                           capture_output=True, check=True)
            plain = (sdr / "sample-hyperdr.jpg").read_bytes()
            xmp = b"http://ns.adobe.com/xap/1.0/\0<x:xmpmeta xmlns:hdrgm=\"http://ns.adobe.com/hdr-gain-map/1.0/\"/>"
            xmp_only = root / "xmp-only.jpg"
            xmp_only.write_bytes(plain[:2] + b"\xff\xe1" + (len(xmp) + 2).to_bytes(2, "big") + xmp + plain[2:])
            refused = subprocess.run([CLI, "verify", str(xmp_only)], capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("not an ISO gain-map JPEG", refused.stderr)
            # ISO plus Ultra HDR XMP (as Android 15 writes) is named as such.
            # The segment goes before MPF, so the gain image's MPF offset (relative
            # to the MPF header) still holds; only the primary's size grows.
            segment = b"\xff\xe1" + (len(xmp) + 2).to_bytes(2, "big") + xmp
            both_bytes = bytearray(outputs["iso-gainmap-jpeg"][:2] + segment + outputs["iso-gainmap-jpeg"][2:])
            header = both_bytes.index(b"MPF\0") + 4
            order = "little" if both_bytes[header:header + 2] == b"II" else "big"
            word = lambda at, n: int.from_bytes(both_bytes[at:at + n], order)
            ifd = header + word(header + 4, 4)
            for tag in range(word(ifd, 2)):
                entry = ifd + 2 + tag * 12
                if word(entry, 2) == 0xB002:
                    size_at = header + word(entry + 8, 4) + 4
                    both_bytes[size_at:size_at + 4] = (word(size_at, 4) + len(segment)).to_bytes(4, order)
            both = root / "iso-and-xmp.jpg"
            both.write_bytes(bytes(both_bytes))
            refused = subprocess.run([CLI, "verify", str(both)], capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("also carries Ultra HDR XMP (hdrgm)", refused.stderr)

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
                    for encoding, extension in (("sdr-jpeg", "jpg"), ("iso-gainmap-jpeg", "jpg"),
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

    def test_gain_jpeg_input_cli_abi_and_repetition(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codecs")
        fixtures = Path(__file__).resolve().parents[1] / "fixtures/gain-map-jpeg"
        golden = json.loads((Path(__file__).parent / "golden/gain_jpeg_input.json").read_text())
        for name in ("iso-mono.jpg", "iso-rgb.jpg", "xmp-only.jpg", "xmp-and-iso.jpg"):
            source = fixtures / name
            with self.subTest(input=name), tempfile.TemporaryDirectory(prefix="hyperdr-gain-input-") as temporary:
                root = Path(temporary)
                destination, report_path = root / "out", root / "report.json"
                request = {"encoding": "iso-gainmap-jpeg", "command": {
                    "input": str(source), "output": str(destination), "overwrite": True}}
                report, _ = self.compare_export(request,
                    ["convert", str(source), "--output", str(destination),
                     "--encoding", "iso-gainmap-jpeg", "--report", str(report_path)],
                    destination / (source.stem + "-hyperdr.jpg"), report_path)
                self.assertEqual(hashlib.sha256((destination / (source.stem + "-hyperdr.jpg")).read_bytes()).hexdigest(), golden["cases"][name])
                session = Handle()
                checked(LIB.hyperdr_preview_open, self.engine, os.fsencode(source), None, ctypes.byref(session))
                try:
                    target = root / "preview.hpf"
                    subprocess.run([CLI, "preview-frame", str(source), "--output", str(target)], capture_output=True, check=True)
                    first = self.packet(LIB.hyperdr_preview_render, session, {"command": {"compact": False}})
                    self.assertEqual(first, target.read_bytes())
                    self.assertEqual(first, self.packet(LIB.hyperdr_preview_render, session, {"command": {"compact": False}}))
                finally:
                    LIB.hyperdr_preview_close(session)

    def test_iso_jpeg_structure_and_rendered_headroom(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codecs")
        with tempfile.TemporaryDirectory(prefix="hyperdr-iso-jpeg-") as temporary:
            root = Path(temporary)
            source, destination, report_path = root / "sample.png", root / "out", root / "report.json"
            png(source, 128, 96)
            request = {"encoding": "iso-gainmap-jpeg", "command": {
                "input": str(source), "output": str(destination), "overwrite": True}}
            report, _ = self.compare_export(request,
                ["convert", str(source), "--output", str(destination), "--encoding", "iso-gainmap-jpeg",
                 "--report", str(report_path)], destination / "sample-hyperdr.jpg", report_path)
            golden = json.loads((Path(__file__).parent / "golden/iso_gain_map_jpeg.json").read_text())
            self.assertEqual(hashlib.sha256((destination / "sample-hyperdr.jpg").read_bytes()).hexdigest(), golden["sha256"])
            file = report["files"][0]
            self.assertIn("percentiles_stops", file["gain_map"])
            inspection = json.loads(subprocess.check_output(
                [CLI, "inspect", str(destination / "sample-hyperdr.jpg"), "--json"]))
            for key in ("primary_iso_segments", "gain_iso_segments", "mpf_segments"):
                self.assertEqual(inspection[key], 1)
            self.assertFalse(inspection["has_hdrgm"])
            self.assertFalse(inspection["has_container_directory"])
            self.assertAlmostEqual(inspection["alternate_headroom"], file["headroom_stops"], delta=.001)
            self.assertAlmostEqual(file["headroom_stops"], file["render"]["headroom_stops"], delta=.01)
            for channel in inspection["channel_metadata"]:
                self.assertEqual(channel["base_offset"], 1 / 64)
                self.assertEqual(channel["alternate_offset"], 1 / 64)

    def test_iso_jpeg_at_zero_headroom_is_sdr_with_a_token_alternate(self):
        # An explicit zero headroom keeps the format: zero gain, AlternateHeadroom
        # one 2^-23 step over BaseHeadroom (ISO divides by their difference),
        # and the report still says 0.
        if not self.capabilities["codecs"]:
            self.skipTest("requires codecs")
        with tempfile.TemporaryDirectory(prefix="hyperdr-iso-jpeg-zero-") as temporary:
            root = Path(temporary)
            source, destination, report_path = root / "sample.png", root / "out", root / "report.json"
            png(source, 128, 96)
            request = {"encoding": "iso-gainmap-jpeg", "headroom": 0, "command": {
                "input": str(source), "output": str(destination), "overwrite": True}}
            reports = self.compare_export(request,
                ["convert", str(source), "--output", str(destination), "--encoding", "iso-gainmap-jpeg",
                 "--headroom", "0", "--report", str(report_path)],
                destination / "sample-hyperdr.jpg", report_path)
            for report in reports:
                file = report["files"][0]
                self.assertEqual(file["headroom_stops"], 0)
                self.assertEqual(file["render"]["headroom_stops"], 0)
            inspection = json.loads(subprocess.check_output(
                [CLI, "inspect", str(destination / "sample-hyperdr.jpg"), "--json"]))
            self.assertEqual(inspection["base_headroom"], 0)
            self.assertAlmostEqual(inspection["alternate_headroom"], 2 ** -23, delta=1e-15)
            for channel in inspection["channel_metadata"]:
                self.assertEqual(channel["gain_min"], 0)
                self.assertEqual(channel["gain_max"], 0)
            subprocess.run([CLI, "verify", str(destination / "sample-hyperdr.jpg")],
                           check=True, capture_output=True)

    def test_iso_jpeg_cancel_during_encoding_leaves_no_file(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codecs")
        with tempfile.TemporaryDirectory(prefix="hyperdr-iso-cancel-") as temporary:
            root = Path(temporary)
            source = root / "large.png"
            width, height = 4000, 3000
            def chunk(kind, payload):
                return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
            rows = (b"\0" + b"\x60\x90\xb0" * width) * height
            source.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
            del rows
            ready = threading.Event()
            callback = CALLBACK(lambda _, event: ready.set() if json.loads(event).get("phase") == "encode" else None)
            cancel = LIB.hyperdr_cancel_create()
            error = ctypes.POINTER(Error)()
            output = ctypes.c_void_p()
            status = []
            request = {"encoding": "iso-gainmap-jpeg", "command": {"input": str(source), "output": str(root / "out")}}
            def work():
                status.append(LIB.hyperdr_convert(self.engine, encoded(request), callback, None, cancel,
                    ctypes.byref(output), ctypes.byref(error)))
            thread = threading.Thread(target=work)
            thread.start()
            try:
                self.assertTrue(ready.wait(30), "encoder did not start")
                time.sleep(.05)
                self.assertTrue(thread.is_alive(), "test image encoded before cancellation")
                begin = time.perf_counter()
                LIB.hyperdr_cancel_request(cancel)
                thread.join(30)
                elapsed = time.perf_counter() - begin
                self.assertFalse(thread.is_alive())
                self.assertNotEqual(status, [0])
                self.assertEqual(error.contents.code, b"cancelled")
                self.assertLess(elapsed, ENCODE_CANCEL_LIMIT)
                self.assertFalse(list((root / "out").glob("*.jpg")))
                self.assertFalse(list((root / "out").glob("*.tmp")))
                print(f"ISO JPEG encode cancel: {elapsed * 1000:.2f} ms", flush=True)
            finally:
                LIB.hyperdr_cancel_request(cancel)
                thread.join(30)
                LIB.hyperdr_error_free(error)
                LIB.hyperdr_string_free(output)
                LIB.hyperdr_cancel_destroy(cancel)

    def test_jpeg_dimension_limit_is_a_per_file_failure(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codecs")
        with tempfile.TemporaryDirectory(prefix="hyperdr-jpeg-limit-") as temporary:
            root = Path(temporary)
            source = root / "wide.png"
            png(source, 65501, 2)
            for encoding in ("sdr-jpeg", "iso-gainmap-jpeg"):
                destination = root / encoding
                request = {"encoding": encoding, "command": {
                    "input": str(source), "output": str(destination), "overwrite": True}}
                report = json.loads(result(LIB.hyperdr_convert, self.engine, encoded(request),
                    CALLBACK(), None, None))
                file = report["files"][0]
                self.assertFalse(file["success"])
                self.assertEqual(file["error_code"], "export_dimension_limit")
                self.assertIn("65501x2", file["detail"])
                self.assertIn("65500", file["detail"])
                self.assertFalse(list(destination.glob("*.jpg")))
                report_path = root / "report.json"
                status = subprocess.run([CLI, "convert", str(source), "--output", str(destination),
                    "--encoding", encoding, "--report", str(report_path)], capture_output=True)
                self.assertNotEqual(status.returncode, 0)
                cli_file = json.loads(report_path.read_bytes())["files"][0]
                self.assertEqual(cli_file["error_code"], file["error_code"])
                self.assertEqual(cli_file["detail"], file["detail"])
                self.assertFalse(list(destination.glob("*.jpg")))

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
            request = {"encoding": "iso-gainmap-jpeg", "gain_strength": .654321, "command": {
                "input": str(source), "output": str(destination),
                "model_id": "research-cnn-v1", "model_mode": True, "overwrite": True, **post}}
            flags = [item for key, value in post.items() for item in (key, str(value))]
            arguments = ["convert", str(source), "--output", str(destination),
                         "--encoding", "iso-gainmap-jpeg", "--report", str(report_path),
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
            for has_profile in (False,):
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
                for encoding, extension in (("sdr-jpeg", "jpg"), ("iso-gainmap-jpeg", "jpg"),
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

    def test_wide_variant_export_matches_cli_with_caption_overlay(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        golden = json.loads((Path(__file__).parent / "golden/frame_variants.json").read_text())
        with tempfile.TemporaryDirectory(prefix="hyperdr-wide-frame-") as temporary:
            root = Path(temporary)
            for width in (400, 1000):
                source = root / "sample.png"
                png(source, width, 100)
                spec = {**golden["spec"], "overlay": "caption.png"}
                layout = json.loads(result(LIB.hyperdr_frame_layout, encoded(spec), width, 100))
                self.assertEqual(layout["variant"], "wide")
                png(root / "caption.png", layout["caption"]["width"], layout["caption"]["height"])
                frame_file = root / "frame.json"
                frame_file.write_text(json.dumps(spec))
                for encoding, extension in (("iso-gainmap-jpeg", "jpg"), ("sdr-tiff", "tif")):
                    with self.subTest(ratio=width / 100, encoding=encoding):
                        output, report_path = root / encoding, root / "report.json"
                        request = json.loads(result(LIB.hyperdr_normalize_options, encoded({
                            "input": str(source), "output": str(output), "report": str(report_path),
                            "encoding": encoding})))
                        request["command"]["frame"] = str(frame_file)
                        request["command"]["overwrite"] = True
                        arguments = json.loads(result(LIB.hyperdr_command_line, encoded(request)))[1:]
                        report, cli_report = self.compare_export(request, arguments,
                            output / ("sample-hyperdr." + extension), report_path)
                        frame = report["files"][0]["frame"]
                        self.assertEqual(frame["variant"], "wide")
                        self.assertEqual((frame["width"], frame["height"]), (layout["width"], layout["height"]))
                        self.assertEqual(frame, cli_report["files"][0]["frame"])

    def test_lut_resources_are_one_snapshot_for_the_whole_batch(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-lut-snapshot-") as temporary:
            root = Path(temporary)
            inputs = root / "inputs"
            inputs.mkdir()
            for name in ("first", "second"):
                png(inputs / (name + ".png"), 128, 96)
            lut = root / "look.cube"
            a = 'LUT_3D_SIZE 2\n' + ''.join(f'{r} {g} {b}\n' for b in (0, 1) for g in (0, 1) for r in (0, 1))
            b = 'LUT_3D_SIZE 2\n' + ''.join(f'{1-r} {g} {bl}\n' for bl in (0, 1) for g in (0, 1) for r in (0, 1))
            lut.write_text(a)
            request = json.loads(result(LIB.hyperdr_normalize_options, encoded({
                "input": str(inputs), "output": str(root / "baseline"), "encoding": "sdr-jpeg",
                "report": str(root / "report.json"), "_lut_path": str(lut)})))

            def convert(callback=CALLBACK()):
                report = json.loads(result(LIB.hyperdr_convert, self.engine, encoded(request), callback, None, None))
                self.assertTrue(all(f["success"] for f in report["files"]), report)
                files = {Path(f["output"]).name: Path(f["output"]).read_bytes() for f in report["files"]}
                return report, files

            baseline, expected = convert()
            request["command"]["output"] = str(root / "race")
            events = []
            def mutate(_, message):
                if json.loads(message)["phase"] == "process":
                    events.append(1)
                    lut.write_text(b)
            raced, actual = convert(CALLBACK(mutate))
            self.assertEqual(len(events), 2)
            self.assertEqual(actual, expected)
            self.assertEqual(raced["color_lut"], baseline["color_lut"])
            # Reports must not reopen a path even if it disappears mid-convert.
            lut.write_text(a)
            request["command"]["output"] = str(root / "removed")
            def remove(_, message):
                if json.loads(message)["phase"] == "process":
                    lut.unlink(missing_ok=True)
            removed, actual = convert(CALLBACK(remove))
            self.assertEqual(actual, expected)
            self.assertEqual(removed["color_lut"], baseline["color_lut"])
            lut.write_text(a)
            request["command"]["output"] = str(root / "race")
            request["command"]["skip_existing"] = True
            resumed, actual = convert()
            self.assertTrue(all(f["skipped"] for f in resumed["files"]))
            self.assertEqual(actual, expected)
            arguments = json.loads(result(LIB.hyperdr_command_line, encoded(request)))[1:]
            subprocess.run([CLI, *arguments, "--skip-existing"], capture_output=True, check=True)
            self.assertTrue(all(f["skipped"] for f in json.loads((root / "report.json").read_bytes())["files"]))
            lut.write_text(b)
            changed, actual = convert()
            self.assertTrue(all(not f["skipped"] for f in changed["files"]))
            self.assertNotEqual(actual, expected)

    def test_raw_profiles_and_external_gain_use_captured_bytes(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        for resource in ("external-gain", "external-report"):
            with self.subTest(resource=resource), tempfile.TemporaryDirectory(prefix="hyperdr-calibration-snapshot-") as temporary:
                root = Path(temporary)
                source = root / "source.dng"
                synthetic_dng(source, focal_length=True)
                profile = root / "camera.dcp"
                dcp(profile, camera_model="")
                target = profile
                edit = {"input": str(source), "output": str(root / "baseline"), "encoding": "sdr-jpeg",
                        "report": str(root / "report.json")}
                if resource in ("dcp", "xmp"):
                    edit["_raw_profile_path"] = str(profile)
                if resource == "xmp":
                    target = root / "look.xmp"
                    target.write_text('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="rdf"><rdf:Description xmlns:crs="crs" crs:PresetType="Look" crs:CameraProfile="Synthetic"><crs:ToneCurvePV2012><rdf:Seq><rdf:li>0,0</rdf:li><rdf:li>128,160</rdf:li><rdf:li>255,255</rdf:li></rdf:Seq></crs:ToneCurvePV2012></rdf:Description></rdf:RDF></x:xmpmeta>')
                    edit["_raw_look_path"] = str(target)
                if resource == "lcp":
                    target = root / "lens.lcp"
                    target.write_text('<rdf:RDF><rdf:Description stCamera:CameraRawProfile="True" stCamera:SensorFormatFactor="1"><rdf:li><rdf:Description stCamera:FocalLength="35" stCamera:ApertureValue="2"><stCamera:PerspectiveModel stCamera:Version="2" stCamera:RadialDistortParam1="-0.1"/></rdf:Description></rdf:li></rdf:Description></rdf:RDF>')
                    edit["_lens_profile_path"] = str(target)
                if resource.startswith("external"):
                    source = root / "source.png"
                    png(source, 128, 96)
                    gain, report = root / "gain.f32", root / "gain.json"
                    gain.write_bytes(struct.pack('<4f', 0, .5, 1, .25))
                    report.write_text(json.dumps({"gain_grid_size": [2, 2], "label_contract_id": "hyperdr.apple-gain-label/v2",
                        "gain_metadata": {key: {"numerator": value, "denominator": 1} for key, value in
                            (("base_headroom", 0), ("alternate_headroom", 3), ("gain_min", 0), ("gain_max", 3),
                             ("gamma", 1), ("base_offset", 0), ("alternate_offset", 0))},
                        "gain_file": {"format": "raw_float32_with_required_json_sidecar", "endianness": "little",
                        "scale": "signed_log2_gain", "width": 2, "height": 2, "byte_length": 16,
                        "sha256": hashlib.sha256(gain.read_bytes()).hexdigest()}}))
                    edit.update(input=str(source), external_gain=str(gain), external_gain_report=str(report))
                    target = gain if resource == "external-gain" else report
                original = target.read_bytes()
                request = json.loads(result(LIB.hyperdr_normalize_options, encoded(edit)))
                # Force cache reconstruction as well as the normal decoder.
                for cache in (False, True):
                    LIB.hyperdr_engine_destroy(self.engine)
                    self.engine = Handle()
                    configuration = {"cache_directory": str(root / "cache")} if cache else {}
                    checked(LIB.hyperdr_engine_create, encoded(configuration), ctypes.byref(self.engine))
                    def convert(callback=CALLBACK()):
                        report = json.loads(result(LIB.hyperdr_convert, self.engine, encoded(request), callback, None, None))
                        file = report["files"][0]
                        self.assertTrue(file["success"], report)
                        return file, Path(file["output"]).read_bytes()
                    target.write_bytes(original)
                    request["command"]["output"] = str(root / ("cache-baseline" if cache else "baseline"))
                    _, expected = convert()
                    request["command"]["output"] = str(root / ("cache-race" if cache else "race"))
                    events = []
                    def mutate(_, message):
                        if json.loads(message)["phase"] == "decode":
                            events.append(1)
                            target.unlink(missing_ok=True)
                    _, actual = convert(CALLBACK(mutate))
                    self.assertTrue(events)
                    self.assertEqual(actual, expected)
                    target.write_bytes(original)
                    request["command"]["skip_existing"] = True
                    resumed, actual = convert()
                    self.assertTrue(resumed["skipped"])
                    self.assertEqual(actual, expected)
                    arguments = json.loads(result(LIB.hyperdr_command_line, encoded(request)))[1:]
                    subprocess.run([CLI, *arguments, "--skip-existing"], capture_output=True, check=True)
                    request["command"]["skip_existing"] = False

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
            self.assertEqual(report["schema"], 13)
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

    def test_hevc_exports_match_cli_bytes(self):
        if not self.capabilities["codecs"]:
            self.skipTest("requires codec-enabled build")
        with tempfile.TemporaryDirectory(prefix="hyperdr-hevc-parity-") as temporary:
            root = Path(temporary)
            source = root / "sample.png"
            png(source, 128, 96)
            for encoding, depth in (("adaptive", 8), ("adaptive", 10), ("pq", 10), ("hlg", 10)):
                with self.subTest(encoding=encoding, depth=depth):
                    destination = root / (encoding + str(depth))
                    report = root / "report.json"
                    request = {"encoding": encoding, "command": {"input": str(source), "output": str(destination),
                               "depth": depth, "overwrite": True}}
                    self.compare_export(request, ["convert", str(source), "--output", str(destination),
                        "--encoding", encoding, "--depth", str(depth), "--report", str(report)],
                        destination / "sample-hyperdr.heic", report)

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
                        ("iso-gainmap-jpeg", "jpg"), ("avif-pq", "avif"), ("avif-hlg", "avif")]:
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
                    # Presentation-frame geometry remains in report schema 13.
                    self.assertEqual(report["schema"], 13)
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
