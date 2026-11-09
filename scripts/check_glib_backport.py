#!/usr/bin/env python3
"""Verify the entire published glib crate plus its two-line upstream safety fix.

With --exercise-regression on Linux, compile and execute the same optimized FFI
probe against the untouched release (must fail) and the selected backport (must
pass). No advisory is suppressed and the working vendor source is never mutated.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out/glib-backport"
CRATE_SHA = "233daaf6e83ae6a12a52055f568f9d7cf4671dabb78ff9560ab6da230ce00ee5"
PATCH_SHA = "a742bf59f1b00af0f434623b34e2fd969dc8697d37c796efdf909dd9eb19b854"
CRATE_URL = "https://static.crates.io/crates/glib/glib-0.18.5.crate"
PATCH = ROOT / "patches/glib-0.18.5-variant-str-iter.patch"
VENDOR = ROOT / "vendor/glib"
HARNESS = ROOT / "tests/security/glib-variant"
CHANGED = "src/variant_iter.rs"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def patched(data):
    changes = [
        (b"let p: *mut libc::c_char = std::ptr::null_mut();",
         b"let mut p: *mut libc::c_char = std::ptr::null_mut();"),
        (b"                &p,\n", b"                &mut p,\n"),
    ]
    for before, after in changes:
        assert data.count(before) == 1, "Upstream fix no longer applies exactly once"
        data = data.replace(before, after)
    return data


def verify(crate):
    assert sha(crate.read_bytes()) == CRATE_SHA, "Published crate checksum mismatch"
    assert sha(PATCH.read_bytes()) == PATCH_SHA, "Official fix patch changed"
    original = {}
    with tarfile.open(crate, "r:gz") as archive:
        for member in archive.getmembers():
            assert member.isfile() or member.isdir(), "Unexpected upstream link"
            if member.isfile():
                name = Path(member.name).relative_to("glib-0.18.5")
                assert ".." not in name.parts
                original[name.as_posix()] = archive.extractfile(member).read()
    files = {p.relative_to(VENDOR).as_posix() for p in VENDOR.rglob("*") if p.is_file()}
    assert files == set(original), "Vendored file inventory differs from the release"
    for name, data in original.items():
        path = VENDOR / name
        assert not path.is_symlink(), f"Vendored symlink: {name}"
        expected = patched(data) if name == CHANGED else data
        assert path.read_bytes() == expected, f"Unexpected vendored change: {name}"
    manifest = tomllib.loads((ROOT / "Cargo.toml").read_text(encoding="utf-8"))
    assert manifest["patch"]["crates-io"]["glib"] == {"path": "vendor/glib"}
    lock = tomllib.loads((ROOT / "Cargo.lock").read_text(encoding="utf-8"))
    selected = [p for p in lock["package"] if p["name"] == "glib"]
    assert len(selected) == 1 and selected[0]["version"] == "0.18.5"
    assert "source" not in selected[0] and "checksum" not in selected[0], "Registry glib still selected"
    return original, {
        "status": "PASS", "upstreamURL": CRATE_URL, "crateSHA256": CRATE_SHA,
        "patchSHA256": PATCH_SHA, "upstreamCommit": "b5a4071e439bef2b5eea76c3aa25e5ae84839e34",
        "filesVerified": len(original), "onlyChangedFile": CHANGED,
        "originalFileSHA256": sha(original[CHANGED]),
        "patchedFileSHA256": sha((VENDOR / CHANGED).read_bytes()),
        "licenseSHA256": sha(original["LICENSE"]),
        "lockSelectsLocalPatch": True,
    }


def build_and_run(root, label):
    env = dict(os.environ, CARGO_TARGET_DIR=str(OUT / "target"))
    command = ["cargo", "build", "--locked", "--release", "--message-format=json",
               "--manifest-path", str(root / "tests/security/glib-variant/Cargo.toml")]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", env=env)
    (OUT / f"{label}-build.jsonl").write_text(result.stdout, encoding="utf-8")
    (OUT / f"{label}-build.log").write_text(result.stderr, encoding="utf-8")
    assert result.returncode == 0, f"{label} did not compile; this is not regression evidence"
    artifacts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    binaries = [a["executable"] for a in artifacts if a.get("executable")
                and a.get("target", {}).get("name") == "madi-glib-variant-regression"]
    assert len(binaries) == 1
    binary = Path(binaries[0])
    runs = []
    for mode in ["forward", "reverse", "alternating"]:
        result = subprocess.run([str(binary), mode], capture_output=True, text=True,
                                encoding="utf-8", timeout=30)
        runs.append({"mode": mode, "returncode": result.returncode,
                     "stdout": result.stdout, "stderr": result.stderr})
    return {"binarySHA256": sha(binary.read_bytes()), "runs": runs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-crate", type=Path)
    parser.add_argument("--exercise-regression", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    crate = args.upstream_crate or OUT / "glib-0.18.5.crate"
    if not crate.exists():
        assert args.upstream_crate is None, "Explicit upstream crate is missing"
        with urllib.request.urlopen(CRATE_URL, timeout=60) as response:
            data = response.read()
        assert sha(data) == CRATE_SHA, "Downloaded crate checksum mismatch"
        crate.write_bytes(data)
    report = {"schemaVersion": 1, "status": "FAIL", "regression": "NOT_RUN"}
    try:
        original, provenance = verify(crate)
        report["provenance"] = provenance
        if args.exercise_regression:
            assert platform.system() == "Linux", "Optimized red/green gate requires Linux"
            import resource
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            report["rustc"] = subprocess.check_output(["rustc", "--version"], text=True).strip()
            report["nativeGlib"] = subprocess.check_output(
                ["pkg-config", "--modversion", "glib-2.0"], text=True).strip()
            with tempfile.TemporaryDirectory(prefix="madi-glib-original-") as directory:
                baseline = Path(directory)
                for name, data in original.items():
                    path = baseline / "vendor/glib" / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                harness = baseline / "tests/security/glib-variant"
                shutil.copytree(HARNESS, harness, ignore=shutil.ignore_patterns("target"))
                report["original"] = build_and_run(baseline, "original")
            # A compile failure or assertion failure is not the null-pointer bug.
            # Optimized glib 0.18.5 must crash at its invalid CStr pointer.
            assert all(r["returncode"] in (-11, -6) for r in report["original"]["runs"]), report["original"]
            report["patched"] = build_and_run(ROOT, "patched")
            for run in report["patched"]["runs"]:
                assert run["returncode"] == 0, run
                assert json.loads(run["stdout"]) == {"status": "PASS", "mode": run["mode"]}
            report["regression"] = "RED_TO_GREEN"
        report["status"] = "PASS"
    finally:
        (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
