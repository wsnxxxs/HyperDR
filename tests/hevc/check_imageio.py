"""Independent ImageIO checks of real VideoToolbox HEIF writer output."""
import argparse
import json
import pathlib
import subprocess
import tempfile


def check_writer(fixtures, probe, directory):
    subprocess.run([str(fixtures), str(directory)], check=True)
    for depth in (8, 10):
        for width, height in ((64, 64), (63, 47), (1, 1), (512, 512), (513, 513), (768, 768)):
            path = directory / f"{width}x{height}-{depth}.heic"
            result = json.loads(subprocess.check_output(
                [str(probe), "--require-iso-dimensions", str(width), str(height), str(path)], text=True))
            if result != {"width": width, "height": height, "iso_auxiliary": True}:
                raise RuntimeError(f"ImageIO grid/auxiliary mismatch: {path.name}: {result}")
            print(f"ImageIO {path.name}: dimensions correct, ISO auxiliary true", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--writer-fixtures", required=True, type=pathlib.Path)
    parser.add_argument("--build-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()
    directory = args.build_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    # All derived artifacts remain under the requested build directory.
    with tempfile.TemporaryDirectory(prefix="imageio-", dir=directory) as temporary:
        root = pathlib.Path(temporary)
        probe = root / "imageio_probe"
        subprocess.run(["xcrun", "swiftc", "-O", str(pathlib.Path(__file__).with_name("imageio_probe.swift")),
                        "-o", str(probe)], check=True)
        check_writer(args.writer_fixtures.resolve(), probe, root)


if __name__ == "__main__":
    main()
