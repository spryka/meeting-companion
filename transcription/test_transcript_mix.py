import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import wave

import numpy as np

from transcript_mix import prepare_mix


class TranscriptMixTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.host = self.root / "used-aec-host.wav"
        self.remote = self.root / "remote.wav"
        self.destination = self.root / "playback.m4a"
        self.frames = 48037  # Not an AAC packet multiple.
        self.write(self.host, np.zeros(self.frames, dtype=np.int16))
        self.write(self.remote, np.zeros(self.frames, dtype=np.int16))

    def write(self, path, samples, rate=16000, channels=1, width=2):
        with wave.open(str(path), "wb") as output:
            output.setparams((channels, width, rate, 0, "NONE", "not compressed"))
            output.writeframes(samples.tobytes())

    def snapshot(self):
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.root.iterdir()}

    def assert_rejected_without_changes(self):
        before = self.snapshot()
        with self.assertRaises((ValueError, OSError, EOFError, wave.Error)):
            prepare_mix(self.host, self.remote, self.destination)
        self.assertEqual(self.snapshot(), before)

    @unittest.skipUnless(shutil.which("afconvert"), "requires macOS afconvert")
    def test_real_mix_preserves_pauses_overlap_and_used_host(self):
        t = np.arange(self.frames) / 16000
        host = np.zeros(self.frames, dtype=np.int16)
        remote = host.copy()
        host[8000:32000] = (24000 * np.sin(2 * np.pi * 440 * t[8000:32000])).astype(np.int16)
        remote[16000:40000] = (24000 * np.sin(2 * np.pi * 660 * t[16000:40000])).astype(np.int16)
        self.write(self.host, host)
        self.write(self.remote, remote)
        # A different original must never silently replace the supplied AEC source.
        self.write(self.root / "original-host.wav", np.full(self.frames, 30000, dtype=np.int16))
        before = self.snapshot()
        prepare_mix(self.host, self.remote, self.destination)
        self.assertEqual(set(self.snapshot()), set(before) | {"playback.m4a"})
        for name, digest in before.items():
            self.assertEqual(self.snapshot()[name], digest)
        decoded = self.root / "decoded.wav"
        subprocess.run(["/usr/bin/afconvert", str(self.destination), str(decoded),
                        "-f", "WAVE", "-d", "LEI16@16000"], check=True, capture_output=True)
        with wave.open(str(decoded), "rb") as audio:
            self.assertEqual((audio.getnchannels(), audio.getframerate()), (1, 16000))
            actual = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(float)
        self.assertGreaterEqual(len(actual), self.frames)
        self.assertLessEqual(len(actual) - self.frames, 1023)
        expected = (host.astype(float) + remote.astype(float)) / 2
        # Avoid AAC ringing at segment boundaries, but check each source and overlap.
        for start, end in ((1000, 6000), (10000, 14000), (18000, 30000), (34000, 38000), (42000, 46000)):
            with self.subTest(interval=(start, end)):
                error = np.sqrt(np.mean((actual[start:end] - expected[start:end]) ** 2))
                self.assertLess(error, 650)
        self.assertLess(np.max(np.abs(actual)), 30000)

    @unittest.skipUnless(shutil.which("afconvert"), "requires macOS afconvert")
    def test_silent_nonempty_inputs_are_valid(self):
        prepare_mix(self.host, self.remote, self.destination)
        self.assertGreater(self.destination.stat().st_size, 0)

    def test_invalid_sources_are_rejected(self):
        for kind in ("empty", "text", "rate", "stereo", "width", "unequal", "truncated", "both-truncated"):
            with self.subTest(kind=kind):
                self.write(self.host, np.zeros(self.frames, dtype=np.int16))
                self.write(self.remote, np.zeros(self.frames, dtype=np.int16))
                if kind == "empty":
                    self.write(self.host, np.array([], dtype=np.int16))
                elif kind == "text":
                    self.host.write_text("not audio")
                elif kind == "rate":
                    self.write(self.host, np.zeros(self.frames, dtype=np.int16), rate=8000)
                elif kind == "stereo":
                    self.write(self.host, np.zeros(self.frames * 2, dtype=np.int16), channels=2)
                elif kind == "width":
                    self.write(self.host, np.zeros(self.frames, dtype=np.int32), width=4)
                elif kind == "unequal":
                    self.write(self.host, np.zeros(self.frames - 1, dtype=np.int16))
                else:
                    self.host.write_bytes(self.host.read_bytes()[:-13])
                    if kind == "both-truncated":
                        self.remote.write_bytes(self.remote.read_bytes()[:-13])
                self.assert_rejected_without_changes()

    def test_missing_source_is_rejected(self):
        self.host.unlink()
        self.assert_rejected_without_changes()

    def test_existing_destination_and_originals_are_never_overwritten(self):
        for destination in (self.host, self.remote, self.destination):
            with self.subTest(destination=destination.name):
                if destination == self.destination:
                    destination.write_bytes(b"existing mix")
                before = self.snapshot()
                with self.assertRaises((ValueError, FileExistsError)):
                    prepare_mix(self.host, self.remote, destination)
                self.assertEqual(before, self.snapshot())

    def test_conversion_failure_cleans_partial_outputs(self):
        before = self.snapshot()

        def fail(command, **kwargs):
            self.assertEqual(Path(command[2]).parent, self.destination.parent)
            Path(command[2]).write_bytes(b"partial conversion")
            raise subprocess.CalledProcessError(1, command, stderr=b"injected encoder failure")

        with patch("transcript_mix.subprocess.run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                prepare_mix(self.host, self.remote, self.destination)
        self.assertEqual(before, self.snapshot())

    def test_successful_converter_with_invalid_output_is_rejected(self):
        before = self.snapshot()

        def invalid(command, **kwargs):
            Path(command[2]).write_bytes(b"not valid audio")
            return subprocess.CompletedProcess(command, 0)

        with patch("transcript_mix.subprocess.run", side_effect=invalid):
            with self.assertRaises((ValueError, EOFError, wave.Error)):
                prepare_mix(self.host, self.remote, self.destination)
        self.assertEqual(before, self.snapshot())

    def test_verification_rejects_wrong_duration_and_truncated_decode(self):
        for kind in ("short", "long", "truncated", "decode-failure"):
            with self.subTest(kind=kind):
                before = self.snapshot()

                def convert(command, **kwargs):
                    output = Path(command[2])
                    self.assertEqual(output.parent, self.destination.parent)
                    if output.suffix == ".m4a":
                        output.write_bytes(b"synthetic encoded file")
                    elif kind == "decode-failure":
                        output.write_bytes(b"partial")
                        raise subprocess.CalledProcessError(1, command)
                    else:
                        frames = self.frames - 1 if kind == "short" else self.frames + 1024
                        self.write(output, np.zeros(frames, dtype=np.int16))
                        if kind == "truncated":
                            self.write(output, np.zeros(self.frames, dtype=np.int16))
                            output.write_bytes(output.read_bytes()[:-100])
                    return subprocess.CompletedProcess(command, 0)

                with patch("transcript_mix.subprocess.run", side_effect=convert):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        prepare_mix(self.host, self.remote, self.destination)
                self.assertEqual(before, self.snapshot())

    @unittest.skipUnless(shutil.which("afconvert"), "requires macOS afconvert")
    def test_source_reads_are_bounded_and_all_blocks_are_processed(self):
        self.frames = 16000 * 11 + 37
        self.write(self.host, np.full(self.frames, 24000, dtype=np.int16))
        self.write(self.remote, np.full(self.frames, 24000, dtype=np.int16))
        readframes = wave.Wave_read.readframes
        reads = []

        def bounded(audio, count):
            self.assertGreater(count, 0)
            self.assertLessEqual(count, 65536)
            reads.append(count)
            return readframes(audio, count)

        with patch.object(wave.Wave_read, "readframes", bounded):
            prepare_mix(self.host, self.remote, self.destination)
        self.assertGreaterEqual(len(reads), 9)

    def test_symlink_destination_cannot_replace_an_original(self):
        alias = self.root / "alias.m4a"
        alias.symlink_to(self.host)
        before = self.snapshot()
        with self.assertRaises((ValueError, FileExistsError)):
            prepare_mix(self.host, self.remote, alias)
        self.assertEqual(before, self.snapshot())


if __name__ == "__main__":
    unittest.main()
