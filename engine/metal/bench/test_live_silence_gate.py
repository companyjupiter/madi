#!/usr/bin/env python3
"""Regression tests for silence leaking into the live diarization assigner."""

import os
import re
import struct
import subprocess
import tempfile
import unittest
import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "out/transcribe"
MODEL = ROOT / "assets/model.safetensors"
BPE = ROOT / "assets/WHISPER_BPE.bin"
VAD = ROOT / "assets/silero_vad.bin"
JFK = ROOT / "assets/jfk.wav"
SPEAKER_EVENT = re.compile(r"^(SPKTRACE|SPK|SPKFIX|SPKOV)\s+([0-9.]+)", re.MULTILINE)


def write_silence(path: Path, seconds: int = 10) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(struct.pack("<h", 0) * 16_000 * seconds)


def require(path: Path, label: str) -> None:
    if not path.exists():
        raise unittest.SkipTest(f"{label} not found: {path}")


class LiveSilenceGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        for path, label in (
            (ENGINE, "engine binary"),
            (MODEL, "Whisper model"),
            (BPE, "BPE asset"),
            (VAD, "Silero VAD asset"),
        ):
            require(path, label)

    def run_stream(self, feed: str, roots: list[Path]) -> str:
        env = {
            **os.environ,
            "STREAM": "1",
            "STREAM_WAV_ROOTS": os.pathsep.join(map(str, roots)),
            "DIAR_ONLY": "1",
            "OSD": "0",
            "DIAR_ASSIGN_TRACE": "1",
            # Expose every assign decision instead of coalescing within a job.
            "DIAR_SEGMENT_COHERENT": "0",
        }
        result = subprocess.run(
            [str(ENGINE), str(MODEL), "/dev/null", str(BPE)],
            cwd=ROOT,
            env=env,
            input=feed,
            text=True,
            capture_output=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("<<FLUSH_END>>", result.stdout)
        return result.stdout

    def test_digital_silence_emits_no_speaker_events(self) -> None:
        with tempfile.TemporaryDirectory(prefix="madi-live-silence-") as tmp:
            root = Path(tmp)
            silence = root / "silence.wav"
            write_silence(silence)

            output = self.run_stream(f"0 {silence}\nFLUSH\n", [root])

        self.assertEqual(SPEAKER_EVENT.findall(output), [], output)

    def test_silence_after_speech_never_reaches_assignment(self) -> None:
        require(JFK, "JFK regression fixture")
        with tempfile.TemporaryDirectory(prefix="madi-live-speech-silence-") as tmp:
            root = Path(tmp)
            silence = root / "silence.wav"
            write_silence(silence)
            feed = f"0 {JFK}\n11 {silence}\n21 {silence}\nFLUSH\n"

            output = self.run_stream(feed, [JFK.parent, root])

        events = [(kind, float(ts)) for kind, ts in SPEAKER_EVENT.findall(output)]
        self.assertTrue(events, "speech control emitted no speaker events\n" + output)
        leaked = [(kind, ts) for kind, ts in events if ts >= 11.0]
        self.assertEqual(leaked, [], output)


if __name__ == "__main__":
    unittest.main()
