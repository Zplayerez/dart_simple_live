import hashlib
import io
import struct
import unittest
from zipfile import ZipFile

from verify_android_release import signer_fingerprints


def prefixed(value):
    return struct.pack("<I", len(value)) + value


def fixture(schemes):
    stream = io.BytesIO()
    with ZipFile(stream, "w") as archive:
        archive.writestr("AndroidManifest.xml", b"test fixture")
    original = stream.getvalue()
    end = original.rfind(b"PK\x05\x06")
    directory = struct.unpack_from("<I", original, end + 16)[0]
    pairs = b""
    for scheme, certificate in schemes:
        signed_data = prefixed(b"") + prefixed(prefixed(certificate)) + prefixed(b"")
        signer = prefixed(signed_data) + prefixed(b"") + prefixed(b"")
        value = prefixed(prefixed(signer))
        pairs += struct.pack("<QI", len(value) + 4, scheme) + value
    size = len(pairs) + 24
    block = struct.pack("<Q", size) + pairs + struct.pack("<Q", size) + b"APK Sig Block 42"
    apk = bytearray(original[:directory] + block + original[directory:])
    struct.pack_into("<I", apk, end + len(block) + 16, directory + len(block))
    return bytes(apk)


class SigningBlockTest(unittest.TestCase):
    def test_v2_certificate(self):
        certificate = b"synthetic certificate A"
        apk = fixture([(0x7109871A, certificate)])
        self.assertEqual(signer_fingerprints(apk), {hashlib.sha256(certificate).hexdigest()})

    def test_v2_v3_and_v31_agree(self):
        certificate = b"synthetic certificate A"
        apk = fixture([(scheme, certificate) for scheme in [0x7109871A, 0xF05368C0, 0x1B93AD61]])
        self.assertEqual(signer_fingerprints(apk), {hashlib.sha256(certificate).hexdigest()})

    def test_unexpected_rotated_signer_remains_visible(self):
        first, other = b"certificate A", b"certificate B"
        apk = fixture([(0x7109871A, first), (0x1B93AD61, other)])
        self.assertEqual(signer_fingerprints(apk), {hashlib.sha256(value).hexdigest() for value in [first, other]})

    def test_v2_is_required(self):
        with self.assertRaises(ValueError):
            signer_fingerprints(fixture([(0xF05368C0, b"certificate A")]))

    def test_truncated_apk_is_rejected(self):
        with self.assertRaises(ValueError):
            signer_fingerprints(fixture([(0x7109871A, b"certificate A")])[:-8])


if __name__ == "__main__":
    unittest.main()
