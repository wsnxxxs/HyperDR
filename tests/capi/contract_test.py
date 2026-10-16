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

class EngineContract(unittest.TestCase):
    def setUp(self):
        self.engine = Handle()
        checked(LIB.hyperdr_engine_create, b"{}", ctypes.byref(self.engine))
        self.capabilities = json.loads(result(LIB.hyperdr_capabilities, self.engine))

    def tearDown(self):
        LIB.hyperdr_engine_destroy(self.engine)

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
                    settings.pop("command")
                    self.assertEqual(settings, case["settings"])
                    self.assertEqual(json.loads(result(LIB.hyperdr_command_line, normalized)), case["argv"])

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
                    # Report remains the existing schema 11.
                    self.assertEqual(report["schema"], 11)
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
