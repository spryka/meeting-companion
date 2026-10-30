import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("transcribe", Path(__file__).with_name("transcribe.py"))
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


class TranscriberTests(unittest.TestCase):
    def test_shared_text_hides_technical_home_paths_without_rewriting_speech(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "shared.txt"
            audio = Path.home() / "Meetings" / "source.wav"
            lines = t.transcript_lines(audio, [], "disabled", 1, fallback_text="Keep spoken /Users/example")
            lines.insert(1, "Warning: failed " + str(Path.home() / "cache/model"))
            t.write_transcript(output, lines)
            text = output.read_text()
            self.assertIn("Audio: source.wav", text)
            self.assertIn("Warning: failed ~/cache/model", text)
            self.assertIn("Keep spoken /Users/example", text)
            self.assertNotIn(str(audio), text)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.audio = self.root / "audio.wav"
        self.audio.write_bytes(b"original audio")
        self.output = self.root / "out.txt"

    def run_main(self, *args, diarization_error=False, diarization_result=([], 0)):
        def transcribe(*args, **kwargs):
            return {"segments": [{"start": 0, "end": 2, "text": "Test"}]}
        with patch.object(sys, "argv", ["transcribe", *map(str, args)]), \
             patch.object(t, "run_gigaam", side_effect=transcribe), \
             patch.object(t, "run_nemotron_diarization", side_effect=RuntimeError("test failure")
                          if diarization_error else None, return_value=diarization_result) as engine, \
             contextlib.redirect_stderr(io.StringIO()):
            t.main()
            return engine

    def test_nemotron_dispatch_and_auto_count(self):
        intervals = [SimpleNamespace(start=0.0, end=2.0, speaker=0)]
        engine = self.run_main(self.audio, self.output, diarization_result=(intervals, 1))
        engine.assert_called_once()
        text = self.output.read_text()
        self.assertIn("Diarization backend: nemotron", text)
        self.assertIn("Diarization: enabled", text)
        self.assertIn("[00:00] Speaker 1: Test", text)
        with self.assertRaises(SystemExit):
            self.run_main("--diarization-backend", "nemotron", "--num-speakers", "2", self.audio)

    def test_nemotron_failure_is_visible(self):
        self.run_main(self.audio, self.output, diarization_error=True)
        self.assertIn("Diarization: failed", self.output.read_text())
        self.assertIn("placeholder", self.output.read_text())

    def test_eight_voices_warn_before_word_assignment_reduces_count(self):
        intervals = [SimpleNamespace(start=float(i), end=float(i+1), speaker=i) for i in range(8)]
        self.run_main(self.audio, self.output, diarization_result=(intervals, 8))
        text = self.output.read_text()
        self.assertIn("Nemotron достиг лимита 8", text)
        self.assertIn("не приписывайте", text)
        self.assertLess(text.index("Warning:"), text.index("[00:00]"))
        self.assertIn("Diarization limit:", text)

    def test_fewer_voices_explain_limit_without_claiming_it_was_hit(self):
        self.run_main(self.audio, self.output, diarization_result=(
            [SimpleNamespace(start=0, end=2, speaker=0)], 1))
        text = self.output.read_text()
        self.assertIn("не более 8 голосов", text)
        self.assertNotIn("достиг лимита", text)

    def test_recorder_has_one_text_engine(self):
        self.run_main("--no-diarize", self.audio, self.output)
        self.assertIn("gigaam-v3-e2e-rnnt (MLX / GPU; experiment)", self.output.read_text())
        for option, value in (("--asr-backend", "whisper"), ("--model", "unused"),
                              ("--language", "en"), ("--context-file", "unused")):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                self.run_main(option, value, self.audio, self.output)

    def test_experimental_mlx_selection_does_not_load_onnx(self):
        expected = object()
        modules = {"gigaam_mlx_backend": SimpleNamespace(load_model=lambda: expected),
                   "onnx_asr": SimpleNamespace(load_model=lambda *a, **k: SimpleNamespace(
                       with_timestamps=lambda: "onnx"))}
        with patch.dict(sys.modules, modules), \
             patch.dict(os.environ, {}, clear=True), \
             patch("model_assets.model_path", return_value=self.root):
            self.assertIs(t.load_gigaam_model(), expected)

    def test_gigaam_tokens_join_into_words_and_overlap_has_one_owner(self):
        result = SimpleNamespace(tokens=[" Не", " зна", "ю", ",", " что"], timestamps=[0, 0.4, 0.5, 0.5, 1])
        words = t.gigaam_words(result, 24, 49, 24.5, 48.5)
        self.assertEqual([w["text"] for w in words], ["что"])
        words = t.gigaam_words(result, 0, 25, 0, 24.5)
        self.assertEqual([w["text"] for w in words], ["Не", "знаю,", "что"])
        with self.assertRaises(RuntimeError):
            t.gigaam_words(SimpleNamespace(tokens=["x"], timestamps=[float("nan")]), 0, 25, 0, 25)

    def test_word_timestamps_are_exported_before_paragraph_grouping(self):
        payload = self.root / "words.json"
        self.run_main("--no-diarize", "--segments-json", payload, self.audio, self.output)
        data = json.loads(payload.read_text())
        self.assertEqual(data["segments"], [{"start": 0, "end": 2, "text": "Test"}])
        self.assertEqual(data["diarization"], "Diarization: disabled (1 speakers)")
        for alias in (self.audio, self.output):
            with self.subTest(alias=alias), self.assertRaises(SystemExit):
                self.run_main("--segments-json", alias, self.audio, self.output)
        self.assertEqual(self.audio.read_bytes(), b"original audio")

    def test_nemotron_rejects_empty_and_invalid_intervals(self):
        class CacheMiss(Exception):
            pass
        for raw in ([], [SimpleNamespace(start=float("nan"), end=1.0, speaker=0)],
                    [SimpleNamespace(start=0.0, end=1.0, speaker=8)]):
            model = SimpleNamespace(set_streaming_config=lambda preset: None,
                                    generate=lambda *a, **k: SimpleNamespace(segments=raw))
            modules = {"soundfile": SimpleNamespace(info=lambda *a: SimpleNamespace(samplerate=16000, channels=1),
                                                 read=lambda *a, **k: ([0]*32000, 16000)),
                       "huggingface_hub": SimpleNamespace(snapshot_download=lambda *a, **k: str(self.root)),
                       "huggingface_hub.errors": SimpleNamespace(LocalEntryNotFoundError=CacheMiss),
                       "mlx_audio": SimpleNamespace(),
                       "mlx_audio.vad": SimpleNamespace(load=lambda *a, **k: model)}
            with self.subTest(raw=raw), patch.dict(sys.modules, modules), \
                 patch("model_assets.model_path", return_value=self.root), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    t.run_nemotron_diarization(self.audio)

    def test_input_and_hardlink_cannot_be_overwritten(self):
        alias = self.root / "alias.txt"
        os.link(self.audio, alias)
        for output in (self.audio, alias):
            with self.subTest(output=output), self.assertRaises(SystemExit) as error:
                self.run_main(self.audio, output)
            self.assertEqual(error.exception.code, 2)
            self.assertEqual(self.audio.read_bytes(), b"original audio")

    def test_disabled_and_failed_diarization_have_honest_guides(self):
        for disabled in (True, False):
            with self.subTest(disabled=disabled):
                args = ["--no-diarize"] if disabled else []
                self.run_main(*args, self.audio, self.output, diarization_error=True)
                text = self.output.read_text()
                status = "disabled" if disabled else "failed"
                self.assertIn(f"Diarization: {status}", text)
                self.assertIn("Speaker 1 is a placeholder", text)
                self.assertNotIn("Inferred from", text)

    def test_failed_atomic_write_preserves_existing_transcript(self):
        self.output.write_text("previous transcript")
        with patch.object(Path, "replace", side_effect=OSError("disk failure")):
            with self.assertRaises(SystemExit) as error:
                self.run_main("--no-diarize", self.audio, self.output)
            self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.output.read_text(), "previous transcript")
        self.assertEqual(list(self.root.glob(".out.txt.*")), [])

    def test_shared_pipeline_has_word_exports_and_diarization_events(self):
        words = [{"start": 0, "end": 1, "text": "One"}, {"start": 1, "end": 2, "text": "Two"}]
        events = []
        with patch.object(t, "run_gigaam", return_value={"segments": words}), \
             patch.object(t, "run_nemotron_diarization", return_value=(
                 [SimpleNamespace(start=0, end=1, speaker=0), SimpleNamespace(start=1, end=2, speaker=1)], 2)), \
             contextlib.redirect_stderr(io.StringIO()):
            data = t.transcribe_file(self.audio, self.output, on_progress=lambda *event: events.append(event))
        self.assertEqual([s["speaker"] for s in data["segments"]], [1, 2])
        self.assertEqual(events, [("diarization", 0, 1), ("diarization", 1, 1), ("speakers", 0, 2), ("speakers", 2, 2)])
        self.assertEqual(self.audio.read_bytes(), b"original audio")

    def test_gigaam_progress_counts_actual_windows_without_changing_seams(self):
        import numpy as np
        for seconds, total in ((0, 0), (24, 1), (25, 1), (26, 2), (49, 2), (50, 3)):
            events = []
            model = SimpleNamespace(recognize=lambda *a, **k: SimpleNamespace(tokens=[" word"], timestamps=[1.0]))
            with self.subTest(seconds=seconds), \
                 patch.object(t, "load_audio", return_value=(np.zeros(seconds*16000, dtype="float32"), 16000)), \
                 patch.object(t, "load_gigaam_model", return_value=model):
                data = t.run_gigaam(self.audio, lambda *event: events.append(event))
            self.assertEqual(events, [("gigaam", n, total) for n in range(total+1)])
            self.assertEqual([w["start"] for w in data["segments"]], [24*n+1 for n in range(total)])

    def test_indexed_speaker_assignment_matches_exhaustive_search(self):
        import random
        rng = random.Random(17)
        for trial in range(30):
            intervals = [SimpleNamespace(start=rng.randrange(100)/2, speaker=rng.randrange(8)) for _ in range(60)]
            for d in intervals:
                d.end = d.start + rng.randrange(1, 20)/2
            intervals.sort(key=lambda d: d.start)
            words = [dict(start=rng.randrange(120)/2, text='word') for _ in range(150)]
            for w in words:
                w['end'] = w['start'] + rng.randrange(0, 5)/2
            expected, mapping = [], {}
            for w in words:
                scores = {}
                for d in intervals:
                    amount = min(w['end'], d.end) - max(w['start'], d.start)
                    if amount > 0:
                        scores[d.speaker] = scores.get(d.speaker, 0) + amount
                speaker = (max(scores, key=scores.get) if scores else
                    min(intervals, key=lambda d: min(abs(d.start-w['start']), abs(d.end-w['end']))).speaker)
                mapping.setdefault(speaker, len(mapping)+1)
                expected.append(mapping[speaker])
            result, count = t.assign_speakers(words, intervals)
            self.assertEqual([w['speaker'] for w in result], expected)
            self.assertEqual(count, len(mapping))
        events = []
        result, count = t.assign_speakers([dict(start=0, end=1, text='x')], [], lambda *e: events.append(e))
        self.assertEqual((result[0]['speaker'], count), (1, 1))
        self.assertEqual(events, [('speakers', 0, 1), ('speakers', 1, 1)])

    def test_removed_sherpa_options_are_rejected(self):
        for option, value in (("--num-speakers", "2"), ("--diarization-provider", "coreml"),
                              ("--diarization-backend", "sherpa")):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                self.run_main(option, value, self.audio, self.output)
        self.assertFalse(self.output.exists())

    def test_offline_cache_miss_never_downloads(self):
        class CacheMiss(Exception):
            pass
        calls = []
        def download(*args, **kwargs):
            calls.append(kwargs)
            raise CacheMiss()
        modules = {"huggingface_hub": SimpleNamespace(snapshot_download=download),
                   "huggingface_hub.errors": SimpleNamespace(LocalEntryNotFoundError=CacheMiss),
                   "soundfile": SimpleNamespace(), "mlx_audio": SimpleNamespace(),
                   "mlx_audio.vad": SimpleNamespace(load=lambda *a, **k: None)}
        with patch.dict(sys.modules, modules), patch.dict(os.environ, {"HF_HUB_OFFLINE": "1"}):
            with self.assertRaises(RuntimeError):
                t.run_nemotron_diarization(self.audio)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0]["local_files_only"])


if __name__ == "__main__":
    unittest.main()
