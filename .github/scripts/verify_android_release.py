"""Verify release APK versions, ABIs, and the repository's signing identity."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
from zipfile import ZipFile

def _length_prefixed(data, offset=0):
    if offset + 4 > len(data):
        raise ValueError("Truncated signing data length")
    size = struct.unpack_from("<I", data, offset)[0]
    end = offset + 4 + size
    if end > len(data):
        raise ValueError("Truncated signing data")
    return data[offset + 4:end], end


def signer_fingerprints(apk):
    # Read the documented APK signing block independently of command-line text.
    # apksigner separately verifies the cryptographic signatures below.
    end = apk.rfind(b"PK\x05\x06", max(0, len(apk) - 65557))
    while end >= 0:
        if end + 22 <= len(apk) and end + 22 + struct.unpack_from("<H", apk, end + 20)[0] == len(apk):
            break
        end = apk.rfind(b"PK\x05\x06", max(0, len(apk) - 65557), end)
    if end < 0:
        raise ValueError("ZIP end record missing")
    directory = struct.unpack_from("<I", apk, end + 16)[0]
    if directory < 24 or directory > end or apk[directory - 16:directory] != b"APK Sig Block 42":
        raise ValueError("APK signing block missing")
    size = struct.unpack_from("<Q", apk, directory - 24)[0]
    start = directory - size - 8
    if size < 24 or start < 0 or struct.unpack_from("<Q", apk, start)[0] != size:
        raise ValueError("Invalid APK signing block size")
    offset, limit = start + 8, directory - 24
    fingerprints = set()
    found_v2 = False
    while offset < limit:
        if offset + 12 > limit:
            raise ValueError("Truncated APK signing pair")
        pair_size, scheme = struct.unpack_from("<QI", apk, offset)
        following = offset + 8 + pair_size
        if pair_size < 4 or following > limit:
            raise ValueError("Invalid APK signing pair size")
        if scheme in (0x7109871A, 0xF05368C0, 0x1B93AD61):
            found_v2 |= scheme == 0x7109871A
            signers, _ = _length_prefixed(apk[offset + 12:following])
            signer_offset = 0
            while signer_offset < len(signers):
                signer, signer_offset = _length_prefixed(signers, signer_offset)
                signed_data, _ = _length_prefixed(signer)
                _, digest_end = _length_prefixed(signed_data)
                certificates, _ = _length_prefixed(signed_data, digest_end)
                certificate, _ = _length_prefixed(certificates)
                fingerprints.add(hashlib.sha256(certificate).hexdigest())
        offset = following
    if not found_v2 or not fingerprints:
        raise ValueError("APK v2 signer certificate missing")
    return fingerprints


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", choices=["simple_live_app", "simple_live_tv_app"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    is_tv = args.app == "simple_live_tv_app"
    package = "com.xycz.simple_live_tv" if is_tv else "com.xycz.simple_live"
    metadata = json.loads((root / "assets" / ("tv_app_version.json" if is_tv else "app_version.json")).read_text())
    fingerprints = json.loads((root / ".github/android-release-certificates.json").read_text())
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ["ANDROID_HOME"])
    candidates = [p for p in (sdk / "build-tools").glob("*") if (p / "apksigner").is_file() and (p / "aapt").is_file()]
    if not candidates:
        raise SystemExit("Android SDK build tools are required to verify release APKs")
    build_tools = max(candidates, key=lambda p: tuple(map(int, re.findall(r"\d+", p.name))))
    reports = []
    for abi in ["armeabi-v7a", "arm64-v8a", "x86_64"]:
        apk = root / args.app / "build/app/outputs/flutter-apk" / f"app-{abi}-release.apk"
        signing = subprocess.check_output([str(build_tools / "apksigner"), "verify", "--min-sdk-version", "24", "--verbose", "--print-certs", str(apk)], text=True)
        print(signing, flush=True)
        actual_certificates = signer_fingerprints(apk.read_bytes())
        assert actual_certificates == {fingerprints[args.app]}, f"Unexpected signing certificates for {apk.name}: {sorted(actual_certificates)}"
        badging = subprocess.check_output([str(build_tools / "aapt"), "dump", "badging", str(apk)], text=True)
        attributes = dict(re.findall(r"(\w+)='([^']*)'", badging.splitlines()[0]))
        assert attributes["name"] == package, f"Unexpected application ID: {apk.name}"
        assert attributes["versionName"] == metadata["version"], f"Unexpected application version: {apk.name}"
        with ZipFile(apk) as archive:
            assert archive.testzip() is None, f"Corrupt APK: {apk.name}"
            assert f"lib/{abi}/libapp.so" in archive.namelist(), f"Missing release Dart binary: {apk.name}"
        reports.append({"apk": apk.name, "package": package, "version": attributes["versionName"], "version_code": int(attributes["versionCode"]), "abi": abi, "certificate_sha256": fingerprints[args.app], "signature_v2_verified": True})
    print(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
