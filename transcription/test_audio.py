import tempfile
from pathlib import Path
from unittest import TestCase, main
import numpy as np
import soundfile as sf
from transcribe import load_audio

class AudioTests(TestCase):
    def test_ready_wav_is_read_without_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.wav"
            sf.write(path, np.zeros(16000), 16000, subtype="PCM_16")
            samples, rate = load_audio(path)
            self.assertEqual((samples.shape, rate, str(samples.dtype)), ((16000,), 16000, "float32"))

    def test_wrong_sample_rate_or_stereo_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.wav"
            for samples, rate in ((np.zeros(48000), 48000), (np.zeros((16000, 2)), 16000)):
                sf.write(path, samples, rate, subtype="PCM_16")
                with self.assertRaisesRegex(ValueError, "16 kHz mono WAV"):
                    load_audio(path)

if __name__ == "__main__":
    main()
