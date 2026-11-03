#!/usr/bin/env python3
"""Headless macOS package relocation/helper check. Does not launch native UI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out/desktop-package"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve(strict=True)
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "tv.devart.madi.parity"
    assert info["LSMinimumSystemVersion"] == "14.0"
    executable_name = info["CFBundleExecutable"]
    original_helper = bundle / "Contents/MacOS/madi-audio-decode"
    signature = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], capture_output=True, text=True)
    if signature.returncode:
        raise SystemExit(signature.stderr)
    description = subprocess.run(["codesign", "-d", "--verbose=2", str(bundle)], capture_output=True, text=True, check=True)
    assert "Signature=adhoc" in description.stderr
    # No compiler, Cargo or repo-relative cwd is available to the invoked tools.
    environment = dict(os.environ, PATH="/usr/bin:/bin")
    with tempfile.TemporaryDirectory(prefix="madi-package-relocation-") as directory:
        root = Path(directory)
        relocated = root / bundle.name
        shutil.copytree(bundle, relocated, symlinks=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(relocated)], check=True, capture_output=True)
        executable = relocated / "Contents/MacOS" / executable_name
        helper = relocated / "Contents/MacOS/madi-audio-decode"
        resolved = Path(subprocess.check_output([str(executable), "--native-helper-path"], cwd=root, env=environment, text=True).strip())
        assert resolved == helper.resolve() and digest(helper) == digest(original_helper)
        source = root / "공개 테스트 source.wav"
        with wave.open(str(source), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16000)
            output.writeframes(struct.pack("<h", 1000) * 16000)
        original_hash = digest(source)
        scratch = root / "owned decode"
        scratch.mkdir()
        reply = json.loads(subprocess.check_output([str(resolved), str(source), str(scratch)], cwd=root, env=environment))
        assert reply["status"] == "ok"
        wav = Path(reply["path"]).resolve(strict=True)
        assert wav.is_relative_to(scratch.resolve())
        with wave.open(str(wav), "rb") as output:
            assert (output.getnchannels(), output.getsampwidth(), output.getframerate(), output.getnframes()) == (1, 2, 16000, 16000)
            assert any(output.readframes(16000))
        assert digest(source) == original_hash
        # Remove only the copied helper temporarily: installed resolution must
        # fail instead of using the original checkout's development helper.
        hidden = helper.with_name("decoder-hidden-for-check")
        helper.rename(hidden)
        missing = subprocess.run([str(executable), "--native-helper-path"], cwd=root, env=environment, capture_output=True)
        hidden.rename(helper)
        assert missing.returncode == 1 and not missing.stdout.strip() and b"os error 2" in missing.stderr
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(relocated)], check=True, capture_output=True)
    OUT.mkdir(parents=True, exist_ok=True)
    archive = OUT / "Madi-UI-Parity.app.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(bundle), str(archive)], check=True)
    report = {
        "schemaVersion": 1, "status": "passed", "bundleIdentifier": info["CFBundleIdentifier"],
        "minimumSystemVersion": info["LSMinimumSystemVersion"], "signature": "ad-hoc; deep strict verification passed",
        "relocatedLookup": "passed", "relocatedDecode": "16000 Hz mono PCM16, one second; original preserved",
        "missingHelperFailsClosed": True,
        "helperSHA256": digest(original_helper), "helperBytes": original_helper.stat().st_size,
        "archive": str(archive.relative_to(ROOT)), "archiveSHA256": digest(archive),
        "productRelease": False, "notarized": False,
        "scope": "Headless relocated package/helper only; no UI, microphone, model admission, ASR bundle or updater validation",
    }
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
