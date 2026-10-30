from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


VERIFIER = Path(__file__).resolve().parents[1] / "verify-update.swift"
FIXTURE = """
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = Data("test release".utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: data).base64EncodedString())
"""


class UpdateSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["/usr/bin/xcrun", "swift", "-e", FIXTURE],
            check=True, capture_output=True, text=True, timeout=60,
        )
        cls.public_key, cls.signature = result.stdout.strip().splitlines()

    def verify(self, payload=b"test release", signature=None, length=None):
        with tempfile.TemporaryDirectory(prefix="dimble-signature-test-") as temporary:
            root = Path(temporary)
            (root / "Info.plist").write_bytes(plistlib.dumps({"SUPublicEDKey": self.public_key}))
            (root / "Dimble.dmg").write_bytes(payload)
            signature = self.signature if signature is None else signature
            length = len(payload) if length is None else length
            (root / "appcast.xml").write_text(
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                '<enclosure url="https://example.com/Dimble.dmg" length="' + str(length)
                + '" sparkle:edSignature="' + signature + '"/></item></channel></rss>'
            )
            return subprocess.run(
                ["/usr/bin/xcrun", "swift", str(VERIFIER), str(root / "Info.plist"),
                 str(root / "appcast.xml"), str(root / "Dimble.dmg")],
                capture_output=True, text=True, timeout=60,
            )

    def test_accepts_matching_signature(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_tampered_archive_even_with_matching_length(self):
        result = self.verify(payload=b"fake release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Update signature or length does not match", result.stderr)

    def test_rejects_missing_signature(self):
        result = self.verify(signature="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Update signature or length does not match", result.stderr)

    def test_rejects_wrong_length(self):
        result = self.verify(length=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Update signature or length does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
