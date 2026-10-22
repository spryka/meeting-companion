import hashlib
import os
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from echo_cancellation import cancel_echo, pcm_info


class EchoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def wav(self, name, samples, rate=16000):
        path = self.root / name
        with wave.open(str(path), "wb") as wav:
            wav.setparams((1, 2, rate, 0, "NONE", "not compressed"))
            wav.writeframes(struct.pack("<" + "h" * len(samples), *samples))
        return path

    def fake(self, failure=False):
        path = self.root / "fake-aec"
        path.write_text("#!/usr/bin/env python3\nimport sys\n"
            "host, remote, offset, other, frames = sys.argv[1:]\n"
            "with open(host, 'rb') as f:\n f.seek(int(offset)); sys.stdout.buffer.write(f.read(int(frames)*2))\n"
            "print('AEC_PROGRESS ' + frames + ' ' + frames, file=sys.stderr)\n"
            + ("sys.exit(1)\n" if failure else ""))
        path.chmod(0o700)
        return path

    def test_silent_reference_bypasses_without_binary_and_is_bit_exact(self):
        host = self.wav("host.wav", [0, -32768, 32767, 1, -1] * 1001)
        remote = self.wav("remote.wav", [0] * 5005)
        before = host.read_bytes()
        self.assertEqual(cancel_echo(host, remote, lambda *_: None, self.root / "missing"), host)
        self.assertEqual(host.read_bytes(), before)
        self.assertFalse(host.with_suffix(".aec.wav").exists())

    def test_nonempty_reference_preserves_sources_and_exact_tail(self):
        host = self.wav("host.wav", [42] * 197)
        remote = self.wav("remote.wav", [1] * 197)
        original = [p.read_bytes() for p in (host, remote)]
        progress = []
        result = cancel_echo(host, remote, lambda *value: progress.append(value), self.fake())
        self.assertEqual(result.read_bytes(), host.read_bytes())
        self.assertEqual(pcm_info(result)[0], 197)
        self.assertEqual(progress[-1], (197, 197))
        self.assertEqual(original, [p.read_bytes() for p in (host, remote)])

    def test_failure_keeps_previous_result_and_removes_partial(self):
        host = self.wav("host.wav", [42] * 197)
        remote = self.wav("remote.wav", [1] * 197)
        previous = host.with_suffix(".aec.wav")
        previous.write_bytes(b"previous result")
        with self.assertRaises(RuntimeError):
            cancel_echo(host, remote, lambda *_: None, self.fake(failure=True))
        self.assertEqual(previous.read_bytes(), b"previous result")
        self.assertFalse(list(self.root.glob(".aec-*")))

    def test_mismatched_truncated_and_invalid_format_are_rejected(self):
        host = self.wav("host.wav", [42] * 160)
        remote = self.wav("remote.wav", [1] * 159)
        with self.assertRaises(ValueError): cancel_echo(host, remote, lambda *_: None)
        remote = self.wav("remote.wav", [1] * 160, rate=48000)
        with self.assertRaises(ValueError): cancel_echo(host, remote, lambda *_: None)
        remote = self.wav("remote.wav", [1] * 160)
        remote.write_bytes(remote.read_bytes()[:-2])
        with self.assertRaises(ValueError): cancel_echo(host, remote, lambda *_: None)

    def test_output_alias_cannot_overwrite_microphone(self):
        host = self.wav("host.wav", [42] * 160)
        remote = self.wav("remote.wav", [1] * 160)
        host.with_suffix(".aec.wav").symlink_to(host)
        before = host.read_bytes()
        with self.assertRaises(ValueError): cancel_echo(host, remote, lambda *_: None, self.fake())
        self.assertEqual(host.read_bytes(), before)

    @unittest.skipUnless(os.environ.get("MC_AEC_TEST_BINARY"), "native AEC binary not supplied")
    def test_native_echo_voice_and_mute_without_opening_devices(self):
        import numpy as np
        rng = np.random.default_rng(123)
        rate, count = 16000, 16000 * 20 + 37
        far = rng.normal(0, 2500, count).astype("<i2")
        echo = np.zeros(count, dtype="<i2")
        echo[160:] = (far[:-160] * .55).astype("<i2")
        # First part: echo only; last 5 seconds: independent local voice plus echo.
        voice = np.zeros(count)
        t = np.arange(5 * rate + 37) / rate
        voice[15 * rate:] = 2500 * np.sin(2 * np.pi * 230 * t)
        mic = (echo + voice).astype("<i2")
        mic[18 * rate:19 * rate] = 0  # Recorded mute must remain exactly silent.
        host = self.wav("host.wav", mic.tolist())
        remote = self.wav("remote.wav", far.tolist())
        hashes = [hashlib.sha256(p.read_bytes()).digest() for p in (host, remote)]
        result = cancel_echo(host, remote, lambda *_: None, os.environ["MC_AEC_TEST_BINARY"])
        with wave.open(str(result)) as wav:
            clean = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype(float)
        self.assertEqual(len(clean), count)
        self.assertTrue(np.all(clean[18*rate:19*rate] == 0))
        section = slice(10*rate, 14*rate)
        attenuation = 10*np.log10(np.mean(mic[section].astype(float)**2) / max(np.mean(clean[section]**2), 1e-9))
        self.assertGreater(attenuation, 10)
        self.assertGreater(np.sqrt(np.mean(clean[16*rate:17*rate]**2)), 500)
        self.assertEqual(hashes, [hashlib.sha256(p.read_bytes()).digest() for p in (host, remote)])


if __name__ == "__main__":
    unittest.main()
