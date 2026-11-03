#!/usr/bin/env python3
"""Compare file staging policy to methods extracted verbatim from ContentView.

No UI is opened, no private files are inspected, and no media is decoded. UTType
registration is OS-dependent, so the live Swift result is the reference.
"""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apps/macos/Sovereign/UI/ContentView.swift"
OUT = ROOT / "out/media-file-parity"


def extract(source, name):
    start = source.index(f"    private func {name}(")
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Live media staging comparison requires macOS")
    OUT.mkdir(parents=True, exist_ok=True)
    source = SOURCE.read_text()
    methods = "\n".join(extract(source, name) for name in ("isMediaFile", "fileSizeLabel"))
    driver = OUT / "MediaFileOracle.swift"
    driver.write_text('''import Foundation
import UniformTypeIdentifiers
@main struct Oracle {
''' + methods + '''
    static func main() throws {
        let paths = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let oracle = Oracle()
        let result: [[String: Any]] = paths.map {
            let url = URL(fileURLWithPath: $0)
            return ["accepted": oracle.isMediaFile(url), "summary": ["name": url.lastPathComponent, "sizeLabel": oracle.fileSizeLabel(url)]]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
''')
    binary = OUT / "swift-media-file"
    subprocess.run(["swiftc", "-parse-as-library", str(driver), "-o", str(binary)], check=True)
    subprocess.run(["cargo", "build", "--locked", "-p", "madi-platform", "--example", "media_file_oracle"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="madi-staging-oracle-") as temporary:
        folder = Path(temporary)
        paths = []
        # Known audio/video, known non-media, uppercase, unknown, absent and dot
        # extensions. These names are fixtures, never actual user filenames.
        for index, suffix in enumerate(("wav", "WAV", "mp3", "mp4", "mov", "m4a", "mkv", "webm", "flac", "aiff", "aac", "ogg", "opus", "avi", "mpeg", "pdf", "txt", "png", "zip", "madiunknown", "")):
            path = folder / (f"회의 👩🏽‍💻 fixture {index}" + (f".{suffix}" if suffix else ""))
            path.write_bytes(b"fixture")
            paths.append(str(path))
        for size in (0, 1, 1023, 1024, 1025, 1048575, 1048576, 1101004, 1101005, 1310720, 1572864, 1835008, 2359296, 12345678):
            path = folder / f"size-{size}.wav"
            with path.open("wb") as output:
                output.truncate(size)
            paths.append(str(path))
        paths += [str(folder / ".hidden"), str(folder / "missing.wav"), str(folder)]
        alias = folder / "shortcut.wav"
        alias.symlink_to(folder / "size-12345678.wav")
        paths.append(str(alias))
        payload = json.dumps(paths, ensure_ascii=False).encode()
        swift = json.loads(subprocess.check_output([str(binary)], input=payload))
        rust = json.loads(subprocess.check_output([str(ROOT / "target/debug/examples/media_file_oracle")], input=payload))
        if swift != rust:
            differences = [{"name": Path(paths[i]).name, "swift": left, "rust": right}
                           for i, (left, right) in enumerate(zip(swift, rust)) if left != right]
            raise SystemExit(json.dumps(differences, ensure_ascii=False, indent=2))
        # Omit the random temporary directory name from the stable event digest.
        stable = [record for record, path in zip(rust, paths) if path != str(folder)]
    report = {
        "schemaVersion": 1, "status": "passed", "os": platform.platform(), "cases": len(paths),
        "source": str(SOURCE.relative_to(ROOT)),
        "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "extractedMethodsSHA256": hashlib.sha256(methods.encode()).hexdigest(),
        "resultSHA256": hashlib.sha256(json.dumps(stable, sort_keys=True, ensure_ascii=False).encode()).hexdigest(),
        "scope": "Native drop type policy and metadata only; picker interaction, drag delivery and visual comparison remain manual gates",
    }
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
