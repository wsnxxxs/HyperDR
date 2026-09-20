import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cryptography import x509

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps" / "panel"))
from hyperdr_panel import phone_tls


class PhoneTlsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        environment = dict(os.environ)
        for name in ("HYPERDR_TLS_CERT", "HYPERDR_TLS_KEY", "CAROOT"):
            environment.pop(name, None)
        environment["LOCALAPPDATA"] = self.temp.name
        self.environment = patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_sans_and_root_continuity_on_address_change(self):
        first = phone_tls.prepare(["192.168.1.10", "host.local"])
        self.assertEqual(first["state"], "ready", first)
        root = phone_tls.root_certificate()
        leaf = x509.load_pem_x509_certificate(phone_tls.paths()[0].read_bytes())
        sans = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        self.assertEqual({str(item.value) for item in sans},
                         {"192.168.1.10", "host.local", "localhost", "127.0.0.1", "::1"})
        self.assertEqual(phone_tls.status(["192.168.1.20"])["state"], "renew")
        renewed = phone_tls.prepare(["192.168.1.20"])
        self.assertTrue(renewed["ready"], renewed)
        self.assertEqual(root, phone_tls.root_certificate())
        previous = phone_tls.paths()[0].read_bytes()
        self.assertTrue(phone_tls.prepare(["192.168.1.20"], force=True)["ready"])
        self.assertNotEqual(previous, phone_tls.paths()[0].read_bytes())
        self.assertEqual(root, phone_tls.root_certificate())

    def test_empty_environment_and_missing_optional_dependency(self):
        with patch.dict(os.environ, {"HYPERDR_TLS_CERT": "", "HYPERDR_TLS_KEY": ""}):
            self.assertEqual(phone_tls.paths()[0], phone_tls._directory() / "hyperdr.pem")
            self.assertTrue(phone_tls.status([])["managed"])
            with patch.object(phone_tls, "x509", None):
                result = phone_tls.prepare([])
                self.assertFalse(result["ready"])
                self.assertFalse(result["canPrepare"])
                self.assertIn("pip install", result["error"])
                with self.assertRaisesRegex(ValueError, "pip install"):
                    phone_tls.root_certificate()

    def test_external_configuration_is_read_only(self):
        phone_tls.prepare(["192.168.1.10"])
        original_cert, original_key = phone_tls.paths()
        external = Path(self.temp.name) / "external.pem"
        external.write_bytes(original_cert.read_bytes())
        with patch.dict(os.environ, {"HYPERDR_TLS_CERT": str(external), "HYPERDR_TLS_KEY": str(original_key)}):
            before = external.read_bytes()
            result = phone_tls.prepare(["192.168.1.20"])
            self.assertEqual(result["state"], "external")
            self.assertFalse(result["canPrepare"])
            self.assertEqual(before, external.read_bytes())

    def test_legacy_root_is_preserved_and_missing_key_blocks_rotation(self):
        phone_tls.prepare(["192.168.1.10"])
        root = phone_tls.root_certificate()
        legacy = Path(self.temp.name) / "mkcert"
        (phone_tls._directory() / "ca").rename(legacy)
        result = phone_tls.prepare(["192.168.1.20"])
        self.assertTrue(result["ready"], result)
        self.assertEqual(root, phone_tls.root_certificate())
        self.assertFalse((phone_tls._directory() / "ca").exists())
        (legacy / "rootCA-key.pem").unlink()
        result = phone_tls.prepare(["192.168.1.30"])
        self.assertEqual(result["state"], "renew")
        self.assertFalse(result["canPrepare"])
        self.assertIn("私钥丢失", result["error"])
        self.assertTrue(phone_tls.status(["192.168.1.20"])["ready"])
        self.assertEqual(root, phone_tls.root_certificate())


if __name__ == "__main__":
    unittest.main()
