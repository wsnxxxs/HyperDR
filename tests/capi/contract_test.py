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


if __name__ == "__main__":
    unittest.main()
