import unittest
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import patch
import sys

import numpy as np
import audio_enhancement as a
from model_assets import MODELS


def result(*tokens, text='data API'):
    return NS(text=text, sentences=[NS(tokens=[NS(text=t, start=s, end=e) for t, s, e in tokens])])


class FullMLXTests(unittest.TestCase):
    def test_preparation_selects_mlx_vad_and_q8_parakeet(self):
        self.assertEqual(MODELS['vad']['repo'], 'mlx-community/silero-vad-v6')
        self.assertEqual(MODELS['parakeet']['repo'], 'craquehouse/parakeet-tdt-0.6b-v3-mlx-8bit')
        self.assertIn('model.safetensors', MODELS['parakeet']['files'])

    def test_vad_uses_mlx_timestamps_on_detection_copy(self):
        samples = np.full(50 * 16000, .1, dtype='float32')
        def detect(audio, **kwargs):
            self.assertAlmostEqual(float(audio[0]), .199526, places=5)
            self.assertEqual(kwargs, dict(sample_rate=16000, threshold=.5,
                min_speech_duration_ms=250, min_silence_duration_ms=250, speech_pad_ms=150))
            return [dict(start=24*16000, end=24*16000+1)]
        mask = a.speech_windows(samples, 16000, NS(get_speech_timestamps=detect))
        self.assertEqual(mask, [True, True, False])
        np.testing.assert_array_equal(samples, np.full_like(samples, .1))
        self.assertEqual(a.speech_windows(samples[:0], 16000, None), [])

    def test_vad_rejects_invalid_intervals(self):
        for interval in [dict(start=-1, end=1), dict(start=2, end=1),
                         dict(start=0, end=16001), dict(start=0, end=float('nan')),
                         dict(start='0', end=1)]:
            with self.subTest(interval=interval), self.assertRaises(ValueError):
                a.speech_windows(np.zeros(16000), 16000,
                    NS(get_speech_timestamps=lambda *args, **kwargs: [interval]))

    def test_parakeet_joins_subwords_before_window_seam(self):
        r = result((' da', .4, .6), ('ta', .6, .7), (' API', 1, 1.2), ('.', 1.2, 1.3))
        self.assertEqual(a.parakeet_words(r, 24, 49, 24.5, 48.5),
                         [dict(start=25, end=25.3, text='API.')])
        self.assertEqual(a.parakeet_words(r, 0, 25, 0, 24.5)[0],
                         dict(start=.4, end=.7, text='data'))

    def test_parakeet_rejects_invalid_or_missing_timestamps(self):
        for r in [result(('a', float('nan'), 1)), result(('a', 0, 26)),
                  result(('a', 2, 3), (' b', 1, 2)), result(('a', 1, .5)),
                  result((None, 0, 1)), result(('a', None, 1)),
                  result(('a', 25.1, 25.12)), NS(text='speech', sentences=[])]:
            with self.subTest(result=r), self.assertRaises(RuntimeError):
                a.parakeet_words(r, 0, 25, 0, 24.5)
        self.assertEqual(a.parakeet_words(NS(text='', sentences=[]), 0, 1, 0, 1), [])

    def test_parakeet_masks_windows_and_reports_progress_on_shared_timeline(self):
        calls, progress = [], []
        def generate(samples, **kwargs):
            calls.append(len(samples))
            return result((' test', 1, 1.2), text='test')
        mx = NS(array=np.array, float16=np.float16)
        with patch.dict(sys.modules, {'mlx': NS(core=mx), 'mlx.core': mx}), \
             patch.object(a, 'load_parakeet_model', return_value=NS(generate=generate)), \
             patch('transcribe.load_audio', return_value=(np.zeros(50*16000), 16000)):
            words = a.run_parakeet(Path('synthetic.wav'), [False, True, False],
                                   on_progress=lambda *args: progress.append(args))
            self.assertEqual(words, [dict(start=25, end=25.2, text='test')])
            self.assertEqual(calls, [25*16000])
            self.assertEqual(progress, [('parakeet', i, 3) for i in range(4)])
            with self.assertRaises(ValueError):
                a.run_parakeet(Path('synthetic.wav'), [True])


if __name__ == '__main__':
    unittest.main()
