"""Verify release APK versions, ABIs, and the repository's signing identity."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from zipfile import ZipFile

def signer_fingerprints(output):
    # APK v3.1 uses "Signer (minSdkVersion=..., maxSdkVersion=...)".
    # Match only signer certificates, excluding source stamps and public keys.
    return {
        digest.replace(":", "").lower()
        for digest in re.findall(
            r"^Signer [^\r\n]* certificate SHA-256 digest: ([a-fA-F0-9:]+)\s*$",
            output,
            re.MULTILINE,
        )
    }


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
        signing = subprocess.check_output([str(build_tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)], text=True)
        actual_certificates = signer_fingerprints(signing)
        assert actual_certificates == {fingerprints[args.app]}, f"Unexpected signing certificates for {apk.name}: {sorted(actual_certificates)}"
        assert "Verified using v2 scheme (APK Signature Scheme v2): true" in signing, f"APK v2 signature missing: {apk.name}"
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
