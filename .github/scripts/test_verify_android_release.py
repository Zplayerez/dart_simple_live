import unittest

from verify_android_release import signer_fingerprints


class SignerOutputTest(unittest.TestCase):
    def test_legacy_signer_label(self):
        digest = "ab" * 32
        self.assertEqual(signer_fingerprints(f"Signer #1 certificate SHA-256 digest: {digest}\n"), {digest})

    def test_v31_sdk_range_labels(self):
        digest = "cd" * 32
        output = (
            f"Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: {digest}\n"
            f"Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: {digest}\n"
        )
        self.assertEqual(signer_fingerprints(output), {digest})

    def test_rotated_or_unexpected_identity_remains_visible(self):
        current, other = "ab" * 32, "cd" * 32
        output = (
            f"Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: {other}\n"
            f"Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: {current}\n"
        )
        self.assertNotEqual(signer_fingerprints(output), {current})
        self.assertEqual(signer_fingerprints(output), {current, other})

    def test_source_stamp_and_public_key_cannot_substitute_for_signer(self):
        digest = "ab" * 32
        output = (
            f"Source Stamp Signer certificate SHA-256 digest: {digest}\n"
            f"Signer #1 public key SHA-256 digest: {digest}\n"
        )
        self.assertEqual(signer_fingerprints(output), set())


if __name__ == "__main__":
    unittest.main()
