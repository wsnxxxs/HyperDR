"""Local phone HTTPS certificates. Never changes the operating system trust store."""
from __future__ import annotations

import ipaddress
import os
import socket
import subprocess
import tempfile
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from cryptography import x509
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
except ImportError:
    x509 = None

_DEPENDENCY_ERROR = "手机 HTTPS 需要 cryptography，请运行 python -m pip install -r apps/panel/requirements.txt 后重启。"

_LOCK = threading.RLock()


def _directory() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "HyperDR" / "tls"


def paths() -> tuple[Path, Path]:
    return (Path(os.environ.get("HYPERDR_TLS_CERT") or _directory() / "hyperdr.pem"),
            Path(os.environ.get("HYPERDR_TLS_KEY") or _directory() / "hyperdr-key.pem"))


def _external() -> bool:
    certificate, key = paths()
    return (certificate.resolve() != (_directory() / "hyperdr.pem").resolve()
            or key.resolve() != (_directory() / "hyperdr-key.pem").resolve())


def _names(addresses: list[str]) -> list[str]:
    return sorted(set(addresses) | {"localhost", "127.0.0.1", "::1"})


def _san(address: str):
    try:
        return x509.IPAddress(ipaddress.ip_address(address))
    except ValueError:
        return x509.DNSName(address.encode("idna").decode("ascii"))


def _certificate(path: Path):
    return x509.load_pem_x509_certificate(path.read_bytes())


def _key(path: Path):
    return serialization.load_pem_private_key(path.read_bytes(), password=None)


def _pair(certificate, key):
    def public(value):
        return value.public_key().public_bytes(serialization.Encoding.DER,
                                              serialization.PublicFormat.SubjectPublicKeyInfo)
    if public(certificate) != public(key):
        raise ValueError("证书与私钥不匹配。")


def _root(leaf=None):
    directory = _directory()
    candidates = [directory / "ca"]
    selected = directory / "ca-source.txt"
    if selected.is_file():
        candidates.append(Path(selected.read_text(encoding="utf-8").strip()))
    candidates.append(Path(os.environ.get("CAROOT", str(Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "mkcert"))))
    for candidate in dict.fromkeys(candidates):
        cert_path, key_path = candidate / "rootCA.pem", candidate / "rootCA-key.pem"
        if not cert_path.is_file():
            continue
        try:
            cert = _certificate(cert_path)
            if not cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
                continue
            if leaf is not None:
                leaf.verify_directly_issued_by(cert)
            elif candidate != directory / "ca":
                continue
            return cert, key_path
        except (ValueError, TypeError, InvalidSignature, x509.ExtensionNotFound) as error:
            if leaf is None and candidate == directory / "ca":
                raise ValueError("本地根证书损坏，请恢复原来的 rootCA.pem。") from error
            continue
    if leaf is not None:
        raise ValueError("找不到签发当前证书的根证书；请恢复原来的根证书和私钥，避免更换手机已信任的证书。")
    return None, directory / "ca" / "rootCA-key.pem"


def status(addresses: list[str]) -> dict:
    with _LOCK:
        return _status(addresses)


def _status(addresses: list[str]) -> dict:
    cert_path, key_path = paths()
    result = dict(state="missing", ready=False, managed=not _external(), canPrepare=not _external(),
                  rootAvailable=False, fingerprint="", certificateName="", expiresAt="",
                  addresses=_names(addresses), error="", certificatePath=str(cert_path))
    if x509 is None:
        result.update(state="error", canPrepare=False, error=_DEPENDENCY_ERROR)
        return result
    try:
        if not cert_path.exists():
            if key_path.exists():
                raise ValueError("私钥存在但证书丢失，请恢复证书后重试。")
            if _external():
                raise ValueError("自定义 TLS 证书不存在，请检查 HYPERDR_TLS_CERT 和 HYPERDR_TLS_KEY。")
            root, root_key = _root()
            if root is not None:
                _pair(root, _key(root_key))
            return result
        leaf = _certificate(cert_path)
        _pair(leaf, _key(key_path))
        result.update(certificateName=leaf.subject.rfc4514_string(), expiresAt=leaf.not_valid_after_utc.isoformat())
        now = datetime.now(timezone.utc)
        sans = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        covers = all(_san(name) in sans for name in result["addresses"])
        valid = leaf.not_valid_before_utc <= now < leaf.not_valid_after_utc
        if _external():
            result.update(state="external", ready=valid and covers)
            if not result["ready"]:
                result["error"] = "自定义证书已过期、尚未生效或未覆盖所有访问地址，请自行更新。"
            return result
        root, root_key = _root(leaf)
        common_names = root.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
        result.update(rootAvailable=True, fingerprint=root.fingerprint(hashes.SHA256()).hex(),
                      certificateName=common_names[0].value if common_names else root.subject.rfc4514_string(),
                      rootExpiresAt=root.not_valid_after_utc.isoformat())
        if not root.not_valid_before_utc <= now < root.not_valid_after_utc:
            raise ValueError("根证书已过期或尚未生效，需要重新配置手机信任。")
        renew = not valid or not covers or leaf.not_valid_after_utc <= now + timedelta(days=30)
        result.update(state="renew" if renew else "ready", ready=valid and covers)
        if not root_key.is_file():
            result.update(canPrepare=False, error="根证书私钥丢失；现有证书仍可使用，但续期前请恢复 rootCA-key.pem，不会自动更换根证书。")
        else:
            try:
                _pair(root, _key(root_key))
            except (OSError, ValueError, TypeError) as error:
                result.update(canPrepare=False, error=f"根证书私钥无法用于续期：{error}")
    except Exception as error:
        result.update(state="external" if _external() else "error", ready=False, canPrepare=False,
                      error=f"证书检查失败：{error}")
    return result


def _write(path: Path, data: bytes, private=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".hyperdr-")
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        if private:
            if os.name == "nt":
                identity = subprocess.check_output(["whoami"], text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip()
                subprocess.run(["icacls", temporary, "/inheritance:r", "/grant:r", f"{identity}:F"],
                               check=True, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _save_pair(cert_path, key_path, cert, key):
    _pair(cert, key)
    old_key = key_path.read_bytes() if key_path.exists() else None
    _write(key_path, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                     serialization.NoEncryption()), private=True)
    try:
        _write(cert_path, cert.public_bytes(serialization.Encoding.PEM))
    except Exception:
        if old_key is None:
            key_path.unlink(missing_ok=True)
        else:
            _write(key_path, old_key, private=True)
        raise


def prepare(addresses: list[str], *, force: bool = False) -> dict:
    with _LOCK:
        current = status(addresses)
        if not current["canPrepare"] or (current["state"] == "ready" and not force):
            return current
        try:
            cert_path, key_path = paths()
            leaf = _certificate(cert_path) if cert_path.exists() else None
            root, root_key_path = _root(leaf)
            now = datetime.now(timezone.utc)
            if root is None:
                root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
                name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"HyperDR {socket.gethostname()[:40]} CA")])
                root = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                        .public_key(root_key.public_key()).serial_number(x509.random_serial_number())
                        .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=3650))
                        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                        .add_extension(x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False)
                        .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
                        .sign(root_key, hashes.SHA256()))
                _save_pair(root_key_path.with_name("rootCA.pem"), root_key_path, root, root_key)
            else:
                root_key = _key(root_key_path)
                _pair(root, root_key)
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            leaf = (x509.CertificateBuilder()
                    .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "HyperDR Phone HTTPS")]))
                    .issuer_name(root.subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
                    .not_valid_before(now - timedelta(minutes=5))
                    .not_valid_after(min(now + timedelta(days=365), root.not_valid_after_utc))
                    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                    .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
                    .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root.public_key()), critical=False)
                    .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), critical=True)
                    .add_extension(x509.SubjectAlternativeName([_san(name) for name in _names(addresses)]), critical=False)
                    .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                    .sign(root_key, hashes.SHA256()))
            leaf.verify_directly_issued_by(root)
            if root_key_path.parent != _directory() / "ca":
                _write(_directory() / "ca-source.txt", str(root_key_path.parent).encode("utf-8"))
            _save_pair(cert_path, key_path, leaf, key)
            return status(addresses)
        except Exception as error:
            current.update(state="error", ready=False, error=f"生成 HTTPS 证书失败：{error}")
            return current


def root_certificate() -> bytes:
    with _LOCK:
        return _root_certificate()


def _root_certificate() -> bytes:
    if x509 is None:
        raise ValueError(_DEPENDENCY_ERROR)
    if _external():
        raise ValueError("自定义证书请使用证书提供方的信任配置。")
    cert_path, _ = paths()
    root, _ = _root(_certificate(cert_path) if cert_path.exists() else None)
    if root is None:
        raise ValueError("请先生成 HyperDR 手机 HTTPS 证书。")
    return root.public_bytes(serialization.Encoding.DER)
