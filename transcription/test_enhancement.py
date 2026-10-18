import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import numpy as np

import audio_enhancement as a
import model_assets as assets
from term_correction import cascade
import transcribe as t


class EnhancementTests(unittest.TestCase):
    def test_window_grid_preserves_overlap_and_last_window(self):
        self.assertEqual(list(a.windows(50, 1)), [(0, 25), (24, 49), (48, 50)])
        self.assertEqual(list(a.windows(25, 1)), [(0, 25)])
        self.assertEqual(list(a.windows(0)), [])

    def test_vad_amplifies_only_detection_copy_and_keeps_boundary_speech(self):
        source = np.full(50*16000, .1, dtype='float32')
        before = source.copy()
        def segment(batch, lengths, rate, **kwargs):
            self.assertAlmostEqual(float(batch[0, 0]), .199526, places=5)
            self.assertEqual(rate, 16000)
            return iter([iter([(24*16000, 24*16000+1)])])
        self.assertEqual(a.speech_windows(source, 16000, SimpleNamespace(segment_batch=segment)), [True, True, False])
        np.testing.assert_array_equal(source, before)
        with self.assertRaises(ValueError):
            a.speech_windows(np.array([float('nan')], dtype='float32'), 16000, None)

    def test_gigaam_skips_only_masked_windows_and_preserves_absolute_times(self):
        calls = []
        def recognize(samples, **kwargs):
            calls.append(len(samples))
            return SimpleNamespace(tokens=[' word'], timestamps=[1.0])
        model = SimpleNamespace(recognize=recognize)
        with patch.object(t, 'load_audio', return_value=(np.zeros(50*16000, dtype='float32'), 16000)), \
             patch.object(t, 'load_gigaam_model', return_value=model):
            words = t.run_gigaam(Path('audio.wav'), keep=[False, True, False])['segments']
        self.assertEqual(calls, [25*16000])
        self.assertEqual([word['start'] for word in words], [25.0])

    def test_cascade_preserves_numbers_timing_and_speaker_and_rejects_distant_donor(self):
        g = [dict(start=1, end=1.5, text='гритвей', speaker=2)]
        p = [dict(start=1.1, end=1.5, text='gateway')]
        corrected, changes = cascade(g, p)
        self.assertEqual(corrected, [dict(start=1, end=1.5, text='gateway', speaker=2)])
        self.assertEqual(g[0]['text'], 'гритвей')
        self.assertEqual(len(changes), 1)
        self.assertFalse(cascade(g, [{**p[0], 'start': 10}])[1])
        self.assertFalse(cascade([dict(start=1, end=2, text='2')], [dict(start=1, end=2, text='two')])[1])

    def test_term_replacement_never_consumes_another_speaker(self):
        words = [dict(start=1, end=1.4, text='ордерс', speaker=1),
                 dict(start=1.5, end=2, text='гритвей', speaker=2)]
        donor = [dict(start=1, end=2, text='Orders-Gateway')]
        result, changes = cascade(words, donor)
        self.assertEqual([word['speaker'] for word in result], [1, 2])
        self.assertFalse(any(change['end'] == 2 and change['start'] == 1 for change in changes))

    def test_optional_failures_keep_gigaam_and_report_warnings(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory)/'source.wav'
            output = Path(directory)/'result.txt'
            audio.write_bytes(b'original')
            warning = []
            with patch.object(t, 'run_gigaam', return_value={'segments': [dict(start=1,end=2,text='text')]}), \
                 patch.object(t, 'load_audio', return_value=(np.zeros(16000,dtype='float32'),16000)), \
                 patch.object(a, 'load_vad', side_effect=RuntimeError('missing VAD')), \
                 patch.object(a, 'run_parakeet', side_effect=RuntimeError('missing Parakeet')), \
                 patch('soundfile.info', return_value=SimpleNamespace(frames=16000)), \
                 contextlib.redirect_stderr(io.StringIO()):
                data = t.transcribe_file(audio, output, diarize=False, vad=True, parakeet=True, on_warning=warning.append)
            self.assertEqual(data['segments'], data['gigaam_segments'])
            self.assertEqual(len(warning), 2)
            self.assertIn('original GigaAM retained', data['enhancement'])
            self.assertIn('text', output.with_suffix('.gigaam.txt').read_text())
            self.assertEqual(audio.read_bytes(), b'original')

    def test_baseline_cannot_alias_final_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root/"result.txt"
            output.write_text("keep")
            output.with_suffix(".gigaam.txt").hardlink_to(output)
            with self.assertRaises(ValueError):
                t.transcribe_file(root/"audio.wav", output, parakeet=True)
            self.assertEqual(output.read_text(), "keep")

    def test_model_hash_rejects_corrupt_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = assets.MODELS['vad']
            (root/spec['files'][0]).write_bytes(b'corrupt')
            with self.assertRaises(assets.ModelUnavailable):
                assets.validate_model('vad', root)


if __name__ == '__main__':
    unittest.main()
