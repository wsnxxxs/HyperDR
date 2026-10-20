"""Content identity of the inputs used to build the Apple engine archives."""
from hashlib import sha256
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def engine_fingerprint(root: Path = ROOT) -> str:
    # Content, not HEAD or mtimes: local edits and deletions invalidate the
    # artifact, while unrelated Swift/UI commits do not rebuild the engine.
    inputs = [root / name for name in (
        "CMakeLists.txt", "CMakePresets.json", "vcpkg.json", "vcpkg-configuration.json",
        "scripts/build_xcframework.sh", "scripts/engine_fingerprint.py",
        ".github/scripts/check_licenses.py",
        "apps/apple/Packages/HyperDREngine/Modules/module.modulemap",
    )]
    for directory in ("modules", "cmake", "schema"):
        inputs.extend(path for path in (root / directory).rglob("*") if path.is_file())
    # Match HyperDRBuildIdentity.cmake's embedded-model asset globs: ncnn
    # param/bin/metadata and manifests, excluding CoreML/ONNX/training products.
    models = root / "HyperDR_Model/models"
    for pattern in ("*.ncnn.*", "*.manifest.json"):
        inputs.extend(path for path in models.rglob(pattern) if path.is_file())
    digest = sha256()
    for path in sorted(inputs):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(sha256(path.read_bytes()).digest() if path.is_file() else b"missing")
    return digest.hexdigest()


if __name__ == "__main__":
    print(engine_fingerprint())
