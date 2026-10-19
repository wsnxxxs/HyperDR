from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class VersionConsistencyTests(unittest.TestCase):
    def test_all_release_version_sources_agree(self):
        cmake = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
        header = (
            ROOT / "modules/foundation/include/hyperdr/foundation/version.hpp"
        ).read_text(encoding="utf-8")
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        schema = json.loads((ROOT / "schema/settings.json").read_text(encoding="utf-8"))
        manifest = json.loads((ROOT / "vcpkg.json").read_text(encoding="utf-8-sig"))

        cmake_version = re.search(r"project\(HyperDR VERSION ([0-9.]+)", cmake).group(1)
        header_version = re.search(r'kVersion\[\] = "([0-9.]+)"', header).group(1)
        released_version = re.search(r"^## ([0-9.]+) - ", changelog, re.MULTILINE).group(1)

        versions = {
            cmake_version,
            header_version,
            released_version,
            schema["tool"],
            manifest["version-string"],
        }
        self.assertEqual(len(versions), 1, "release version sources disagree: %r" % versions)


if __name__ == "__main__":
    unittest.main()
