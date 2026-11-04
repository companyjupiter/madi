#!/usr/bin/env python3
"""Headless native metadata/owned-symbol check; never captures a screen or view."""
import base64
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/model-presentation-parity'

def pixels(png):
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', png[16:29])
    assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
    offset, compressed = 8, b''
    while offset < len(png):
        length = struct.unpack('>I', png[offset:offset + 4])[0]
        kind = png[offset + 4:offset + 8]
        data = png[offset + 8:offset + 8 + length]
        if kind == b'IDAT': compressed += data
        offset += length + 12
    raw = zlib.decompress(compressed)
    stride = width * 4
    assert len(raw) == height * (stride + 1)
    previous = bytearray(stride)
    alpha = []
    for y in range(height):
        start = y * (stride + 1)
        algorithm, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left, up, corner = (row[i-4] if i >= 4 else 0), previous[i], (previous[i-4] if i >= 4 else 0)
            p = left + up - corner
            distances = (abs(p-left), abs(p-up), abs(p-corner))
            paeth = (left, up, corner)[distances.index(min(distances))]
            prediction = (0, left, up, (left+up)//2, paeth)[algorithm]
            row[i] = (row[i] + prediction) & 255
        alpha.extend(row[3::4])
        previous = row
    assert min(alpha) == 0 and max(alpha) > 0, 'Symbol must contain transparent and visible pixels'
    return dict(pixelWidth=width, pixelHeight=height, visiblePixels=sum(a > 0 for a in alpha), sha256=hashlib.sha256(png).hexdigest())

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = OUT / 'ModelPresentationOracle.swift'
    source.write_text('''import AppKit
let bytes: [Int64] = [0, 1, 999, 1000, 867485320, 1312165344, 2783447424, 2179650664, 3650932744]
let specs: [(String, String, CGFloat, NSFont.Weight)] = [
    ("header", "waveform", 36, .light), ("required", "waveform", 18, .semibold),
    ("translation", "character.bubble", 18, .semibold), ("privacy", "lock.shield", 11, .regular),
    ("error", "exclamationmark.triangle.fill", 11, .regular), ("follow", "arrow.down", 11, .semibold), ("folder", "folder", 26, .light), ("export", "square.and.arrow.up", 12, .semibold),
    ("play", "play.fill", 15, .regular), ("cancel", "xmark", 15, .semibold),
    ("plus", "plus", 15, .semibold), ("warning", "exclamationmark.triangle", 40, .regular),
    ("micChevron", "chevron.down", 9, .medium),
    ("reviewWarning", "exclamationmark.triangle.fill", 12, .regular),
    ("reviewUp", "chevron.up", 11, .semibold),
    ("reviewDown", "chevron.down", 11, .semibold),
    ("reviewPlay", "play.circle", 13, .regular),
    ("reviewPause", "pause.circle.fill", 13, .regular),
    ("reviewPrevious", "chevron.left", 13, .regular),
    ("reviewNext", "chevron.right", 13, .regular),
    ("linePlay", "play.circle", 12, .regular), ("linePause", "pause.circle.fill", 12, .regular),
    ("caption", "captions.bubble", 12, .regular), ("captionOn", "captions.bubble.fill", 12, .regular),
    ("overlay.caption", "captions.bubble.fill", 12, .regular),
    ("overlay.close", "xmark", 11, .regular), ("overlay.mic", "mic.fill", 10, .regular)]
let symbols = Dictionary(uniqueKeysWithValues: specs.map { key, name, points, weight in
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: points, weight: weight))!
    return (key, ["width": image.size.width, "height": image.size.height])
})
let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd HHmm"
let titles = [0.0, 1735689600.0, 1793800800.0].map { "회의 " + df.string(from: Date(timeIntervalSince1970: $0)) }
let result: [String: Any] = ["liveFallbackTitles": titles, "physicalMemory": ProcessInfo.processInfo.physicalMemory,
    "sizes": bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }, "symbols": symbols]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
''', encoding='utf-8')
    binary = OUT / 'swift-model-presentation'
    subprocess.run(['swiftc', str(source), '-o', str(binary)], check=True)
    expected = json.loads(subprocess.check_output([str(binary)]))
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-platform', '--example', 'model_presentation_oracle'], cwd=ROOT, check=True)
    actual = json.loads(subprocess.check_output([str(ROOT / 'target/debug/examples/model_presentation_oracle')]))
    for key in ('physicalMemory', 'sizes', 'liveFallbackTitles'): assert actual[key] == expected[key], key
    symbols = {}
    artwork = actual['artwork'] | actual['transcriptArtwork'] | {'overlay.' + key: value for key, value in actual['captionArtwork'].items()}
    assert artwork.keys() == expected['symbols'].keys()
    for key, art in artwork.items():
        assert {k: art[k] for k in ('width', 'height')} == expected['symbols'][key]
        png = base64.b64decode(art['dataUrl'].removeprefix('data:image/png;base64,'), validate=True)
        result = pixels(png)
        assert result['pixelWidth'] == math.ceil(art['width'] * 2)
        assert result['pixelHeight'] == math.ceil(art['height'] * 2)
        symbols[key] = dict(width=art['width'], height=art['height'], **result)
    report = dict(schemaVersion=1, status='passed', physicalMemory=actual['physicalMemory'],
                  sizes=actual['sizes'], liveFallbackTitles=actual['liveFallbackTitles'], fallbackTitleCases=3, symbols=symbols, byteCountCases=9, symbolCases=27,
                  scope='Live native Foundation formatting and NSImage symbol dimensions plus nonempty transparent owned PNGs; no SwiftUI/WebView pixel or interaction comparison')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
