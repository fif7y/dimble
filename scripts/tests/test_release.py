import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RELEASE_SCRIPT = Path(__file__).resolve().parents[1] / "release.sh"
TOOL_STUB = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TOOL_LOG"], "a") as log:
    log.write(name + " " + " ".join(args) + "\\n")
if name == "codesign" and "-dvv" in args:
    print("Authority=Test fixture")
if name == "spctl":
    sys.exit(3)
if name == "xcrun" and args[0] == "swift" and os.environ.get("INVALID_SIGNATURE"):
    sys.exit("update signature verification failed")
"""


class ReleaseTests(unittest.TestCase):
    def run_release(self, missing_tool=False, **overrides):
        with tempfile.TemporaryDirectory(prefix="dimble-release-test-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copyfile(RELEASE_SCRIPT, scripts / "release.sh")
            (root / "project.yml").write_text('MARKETING_VERSION: "1.0"\n')
            dmg = scripts / "make-dmg.sh"
            dmg.write_text('#!/bin/bash\nprintf fixture > "$2"\n')
            dmg.chmod(0o700)
            if not missing_tool:
                tool = root / "build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
                tool.parent.mkdir(parents=True)
                tool.write_text('#!/bin/bash\nprintf "<rss/>" > "${@: -1}/appcast.xml"\n')
                tool.chmod(0o700)
            tools = root / "tools"
            tools.mkdir()
            stub = tools / "stub"
            stub.write_text(TOOL_STUB)
            stub.chmod(0o700)
            for name in ("xcodegen", "xcodebuild", "codesign", "xcrun", "spctl", "ditto", "find"):
                (tools / name).symlink_to(stub)
            log = root / "tools.log"
            environment = dict(os.environ, PATH=str(tools) + ":" + os.environ["PATH"], TOOL_LOG=str(log))
            for key in ("SKIP_NOTARIZE", "SPARKLE_KEY_FILE", "CHANNEL"):
                environment.pop(key, None)
            environment.update(overrides)
            result = subprocess.run(
                ["/bin/bash", str(scripts / "release.sh")], env=environment,
                capture_output=True, text=True, timeout=15,
            )
            return result, log.read_text()

    def test_unsigned_stapled_dmg_assessment_does_not_block_verification(self):
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("spctl ", calls)
        self.assertIn("xcrun swift scripts/verify-update.swift ", calls)

    def test_invalid_update_signature_is_fatal(self):
        result, _ = self.run_release(INVALID_SIGNATURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update signature verification failed", result.stderr)
        self.assertNotIn("Done. Artifacts:", result.stdout)

    def test_missing_appcast_tool_is_fatal(self):
        result, _ = self.run_release(missing_tool=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot produce a verified update", result.stderr)

    def test_smoke_mode_still_requires_signature_verification(self):
        result, calls = self.run_release(SKIP_NOTARIZE="1", INVALID_SIGNATURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("spctl ", calls)
        self.assertIn("xcrun swift scripts/verify-update.swift ", calls)


if __name__ == "__main__":
    unittest.main()
