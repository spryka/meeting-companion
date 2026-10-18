import contextlib
import io
import json
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
        g = [dict(start=1, end=1.5, text='датапе', speaker=2)]
        p = [dict(start=1.1, end=1.5, text='data-api')]
        corrected, changes = cascade(g, p)
        self.assertEqual(corrected, [dict(start=1, end=1.5, text='data-api', speaker=2)])
        self.assertEqual(g[0]['text'], 'датапе')
        self.assertEqual(len(changes), 1)
        self.assertFalse(cascade(g, [{**p[0], 'start': 10}])[1])
        self.assertFalse(cascade([dict(start=1, end=2, text='2')], [dict(start=1, end=2, text='two')])[1])

    def test_noise_can_change_local_word_but_cannot_bridge_silence(self):
        words = [dict(start=2, end=2.4, text='Стартуем.'),
                 dict(start=3, end=3.2, text='три.'),
                 dict(start=260, end=260.5, text='Интересно.')]
        donor = [dict(start=2, end=2.4, text='Start'),
                 dict(start=3, end=3.4, text='doing'), dict(start=3.4, end=3.7, text='press')]
        result, rows = cascade(words, donor)
        self.assertEqual(result[1:], words[1:])
        self.assertEqual(result[0]['text'], 'Start')
        self.assertTrue(all(row['end']-row['start'] < 1 for row in rows))
        separated = [dict(start=1, end=1.4, text='дата'), dict(start=260, end=260.4, text='апи')]
        result, rows = cascade(separated, [dict(start=1, end=1.5, text='data-api')])
        self.assertEqual(result[-1], separated[-1])
        self.assertFalse(any(row['source_indices'] == [0, 2] for row in rows))

    def test_donor_phrase_cannot_bridge_pause_even_with_matching_outer_times(self):
        source = [dict(start=1, end=3, text='датаапи')]
        donor = [dict(start=1, end=1.2, text='data'), dict(start=2.5, end=3, text='API')]
        result, rows = cascade(source, donor)
        self.assertFalse(any(row['donor_indices'] == [0, 2] for row in rows))

    def test_term_requires_matching_end_and_overlap(self):
        word = dict(start=1, end=1.5, text='датапе')
        self.assertFalse(cascade([word], [dict(start=1, end=4, text='data-api')])[1])
        self.assertFalse(cascade([word], [dict(start=1.6, end=2, text='data-api')])[1])

    def test_adjacent_terms_are_corrected_without_reusing_words(self):
        words = [dict(start=1.08, end=1.3, text='дата'), dict(start=1.32, end=1.62, text='Апи')]
        donor = [dict(start=1, end=1.3, text='data'), dict(start=1.32, end=1.56, text='API')]
        result, suggestions = cascade(words, donor)
        self.assertEqual(' '.join(row['text'] for row in result), 'data API')
        selected = [row for row in suggestions if row['applied']]
        for key in ('source_indices', 'donor_indices'):
            used = [i for row in selected for i in range(*row[key])]
            self.assertEqual(len(used), len(set(used)))

    def test_moderate_phonetic_similarity_is_accepted(self):
        words = [dict(start=1, end=1.3, text='ордерс'), dict(start=1.4, end=1.8, text='гейтвей')]
        donor = [dict(start=1, end=1.8, text='Orders-Gateway')]
        result, suggestions = cascade(words, donor)
        self.assertEqual(result[0]['text'], 'Orders-Gateway')
        self.assertTrue(any(row['applied'] for row in suggestions))

    def test_overlapping_donor_alternatives_apply_only_once(self):
        words = [dict(start=1, end=1.5, text='абракадабра')]
        donor = [dict(start=1, end=1.5, text='abrakadabra'),
                 dict(start=1, end=1.5, text='abrakadabraa')]
        result, suggestions = cascade(words, donor)
        self.assertEqual(len(result), 1)
        self.assertEqual(sum(row['applied'] for row in suggestions), 1)

    def test_strong_phonetic_match_is_accepted(self):
        words = [dict(start=1, end=1.4, text='Харбор')]
        result, suggestions = cascade(words, [dict(start=1, end=1.4, text='Harbor')])
        self.assertEqual(result[0]['text'], 'Harbor')
        self.assertEqual(suggestions[0]['reason'], 'phonetic')
        self.assertTrue(suggestions[0]['applied'])

    def test_equal_scores_choose_better_temporal_match(self):
        words = [dict(start=1, end=1.5, text='абракадабра')]
        donor = [dict(start=1, end=1.5, text='abrakadabra'),
                 dict(start=1.4, end=1.8, text='abrakadabraa')]
        result, suggestions = cascade(words, donor)
        self.assertEqual(result[0]['text'], 'abrakadabra')
        self.assertEqual(sum(row['applied'] for row in suggestions), 1)

    def test_term_cannot_consume_pronoun(self):
        words = [dict(start=1, end=1.2, text='деплой'), dict(start=1.2, end=1.4, text='мне')]
        donor = [dict(start=1, end=1.4, text='deployment')]
        result, suggestions = cascade(words, donor)
        self.assertEqual(result[-1], words[-1])
        self.assertTrue(any(row['reason'] == 'protected_word' for row in suggestions))
        self.assertFalse(any(row['applied'] and row['source_indices'][1] == 2 for row in suggestions))

    def test_repeated_source_words_choose_better_time_overlap(self):
        words = [dict(start=1, end=1.3, text='датапе'), dict(start=1.35, end=1.5, text='датапе')]
        donor = [dict(start=1, end=1.4, text='data-api')]
        result, suggestions = cascade(words, donor)
        self.assertEqual([row['text'] for row in result], ['data-api', 'датапе'])
        self.assertEqual(sum(row['applied'] for row in suggestions), 1)

    def test_close_source_spans_apply_donor_only_once(self):
        words = [dict(start=1, end=1.3, text='датапе'), dict(start=1.35, end=1.65, text='датапе')]
        donor = [dict(start=1.15, end=1.5, text='data-api')]
        result, suggestions = cascade(words, donor)
        self.assertEqual(len(result), 2)
        self.assertEqual(sum(row['applied'] for row in suggestions), 1)

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

    def test_correction_journal_preserves_inputs_and_explains_change(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'source.wav'
            source.write_bytes(b'original')
            output = Path(directory)/'transcript.txt'
            words = [dict(start=1, end=1.5, text='датапе')]
            donor = [dict(start=1.1, end=1.5, text='data-api')]
            with patch.object(t, 'run_gigaam', return_value={'segments':words}), \
                 patch.object(a, 'run_parakeet', return_value=donor), \
                 patch('soundfile.info', return_value=SimpleNamespace(frames=32000)), \
                 contextlib.redirect_stderr(io.StringIO()):
                data = t.transcribe_file(source, output, diarize=False, parakeet=True)
            journal = json.loads(output.with_suffix('.corrections.json').read_text())
            self.assertEqual(journal['gigaam_segments'], data['gigaam_segments'])
            self.assertEqual(journal['donor_segments'], donor)
            self.assertEqual(journal['changes'][0]['reason'], 'phonetic')
            self.assertEqual(data['segments'][0]['text'], 'data-api')
            self.assertEqual(source.read_bytes(), b'original')

    def test_correction_journal_cannot_alias_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'source.wav'
            source.write_text('keep audio')
            output = Path(directory)/'transcript.txt'
            output.with_suffix('.corrections.json').hardlink_to(source)
            with self.assertRaises(ValueError):
                t.transcribe_file(source, output, parakeet=True)
            self.assertEqual(source.read_text(), 'keep audio')

    def test_protected_suggestions_are_saved_without_changing_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'source.wav'
            source.write_bytes(b'original')
            output = Path(directory)/'transcript.txt'
            words = [dict(start=1, end=1.2, text='для'), dict(start=1.2, end=1.4, text='меня')]
            with patch.object(t, 'run_gigaam', return_value={'segments': words}), \
                 patch.object(a, 'run_parakeet', return_value=[dict(start=1, end=1.4, text='delamenya')]), \
                 patch('soundfile.info', return_value=SimpleNamespace(frames=32000)), \
                 contextlib.redirect_stderr(io.StringIO()):
                data = t.transcribe_file(source, output, diarize=False, parakeet=True)
            self.assertEqual(data['segments'], data['gigaam_segments'])
            self.assertIn('для меня', output.read_text())
            self.assertNotIn('delamenya', output.read_text())
            journal = json.loads(output.with_suffix('.corrections.json').read_text())
            self.assertEqual(journal['changes'], [])
            self.assertEqual(journal['suggestions'][0]['reason'], 'protected_word')
            self.assertIn('0 replacements', data['enhancement'])

    def test_model_hash_rejects_corrupt_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = assets.MODELS['vad']
            (root/spec['files'][0]).write_bytes(b'corrupt')
            with self.assertRaises(assets.ModelUnavailable):
                assets.validate_model('vad', root)


if __name__ == '__main__':
    unittest.main()
