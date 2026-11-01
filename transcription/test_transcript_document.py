"""Tests for structured transcript document (result.json v1) generation and fixtures.

Boundary under test: transcribe-recording.py:main() with mocked ML boundaries.
Verifies that recording.main() outputs a valid structured document adhering to
the JSON v1 contract defined in design.md and specs/transcript-document/spec.md.
"""

import contextlib
import importlib.util
import io
import json
import math
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0, str(Path(__file__).parent))
import transcribe as transcribe_lib

SPEC = importlib.util.spec_from_file_location(
    "recording", Path(__file__).with_name("transcribe-recording.py")
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "transcript-document"


def create_synthetic_wav(path: Path, duration_seconds: float = 1.0):
    """Creates a valid 16 kHz mono PCM16 WAV audio file using standard library wave."""
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16000)
        wav_file.writeframes(b"\x00\x00" * int(16000 * duration_seconds))


class TestTranscriptDocumentGeneration(unittest.TestCase):
    """Behavioral tests verifying structured result.json generation from recording.main()."""

    def make_recording_dir(self, directory: str, base_name: str = "meeting"):
        base = Path(directory) / base_name
        raw = base.parent / "raw"
        raw.mkdir(parents=True, exist_ok=True)
        host, remote = MODULE.source_paths(base)
        create_synthetic_wav(host, 5.0)
        create_synthetic_wav(remote, 5.0)
        return base, host, remote

    def mock_transcribe_data(
        self,
        segments=(),
        gigaam_segments=None,
        status="enabled (1 speakers)",
        speakers_count=1,
        enhancement="disabled",
        warnings=(),
    ):
        return {
            "segments": list(segments),
            "gigaam_segments": list(
                gigaam_segments if gigaam_segments is not None else segments
            ),
            "diarization": f"Diarization: {status}",
            "warnings": list(warnings),
            "enhancement": enhancement,
            "diarization_speakers": speakers_count,
            "diarization_speaker_limit": 8,
        }

    def source_items(self, doc: dict, collection_key: str, source_id: str):
        """Filters words, turns, or baselineWords by looking up item['speakerID'] in doc['speakers'].

        Treats speaker IDs as opaque strings rather than substring patterns.
        """
        speaker_source = {s["id"]: s.get("sourceID") for s in doc.get("speakers", [])}
        return [
            item
            for item in doc.get(collection_key, [])
            if speaker_source.get(item.get("speakerID")) == source_id
        ]

    def run_recording_pipeline(self, base: Path, extra_args=(), patches=(), mock_transcribe=None):
        """Runs MODULE.main() and returns (results, output_txt)."""
        cmd_args = ["recording", str(base), *extra_args]
        output = io.StringIO()
        with patch.object(sys, "argv", cmd_args), contextlib.redirect_stdout(output):
            if patches:
                with contextlib.ExitStack() as stack:
                    for p in patches:
                        stack.enter_context(p)
                    MODULE.main()
            else:
                MODULE.main()

        merged_txt_path = base.with_name(f"{base.name}.sources.transcript.txt")
        self.assertTrue(merged_txt_path.is_file(), "Pipeline failed to produce merged TXT transcript")
        merged_txt = merged_txt_path.read_text(encoding="utf-8")

        if mock_transcribe is not None:
            self.assertEqual(
                mock_transcribe.call_count,
                2,
                "transcribe_file must be called exactly twice (for host and remote)",
            )

        results = list(base.parent.glob("raw/transcripts/*/result.json"))
        return results, merged_txt

    def assert_document_semantics(self, doc: dict):
        """Verifies semantic structure and invariants of result.json according to design.md."""
        self.assertEqual(doc.get("schemaVersion"), 1, "schemaVersion must be integer 1")
        self.assertIsInstance(doc.get("resultID"), str)
        self.assertTrue(doc["resultID"], "resultID must be a non-empty string")
        self.assertIsInstance(doc.get("createdAt"), str)
        self.assertTrue(doc["createdAt"], "createdAt must be non-empty RFC 3339 string")

        # Sources
        self.assertIsInstance(doc.get("sources"), list)
        self.assertEqual(
            {s.get("id") for s in doc["sources"]},
            {"host", "remote"},
            "Sources must contain exactly 'host' and 'remote'",
        )
        for s in doc["sources"]:
            self.assertIn(
                s.get("diarizationStatus"),
                ("completed", "disabled", "failed"),
                f"Invalid diarizationStatus in source {s.get('id')}",
            )
            if s.get("detectedVoiceCount") is not None:
                self.assertIsInstance(s["detectedVoiceCount"], int)
                self.assertGreaterEqual(s["detectedVoiceCount"], 0)
                self.assertLessEqual(s["detectedVoiceCount"], 8)
            self.assertIn(
                s.get("correctionStatus"),
                ("disabled", "completed", "failed"),
                f"Invalid correctionStatus in source {s.get('id')}",
            )
            self.assertIsInstance(s.get("originalAudioPath"), str)
            self.assertIsInstance(s.get("recognitionAudioPath"), str)
            self.assertFalse(s["originalAudioPath"].startswith(".."))
            self.assertFalse(s["originalAudioPath"].startswith("/"))
            self.assertFalse(s["recognitionAudioPath"].startswith(".."))
            self.assertFalse(s["recognitionAudioPath"].startswith("/"))

        # Speakers
        self.assertIsInstance(doc.get("speakers"), list)
        speaker_ids = set()
        display_numbers = set()
        speakers_by_id = {}
        for spk in doc["speakers"]:
            self.assertIsInstance(spk.get("id"), str)
            self.assertTrue(spk["id"])
            self.assertNotIn(spk["id"], speaker_ids, "Duplicate speaker ID")
            speaker_ids.add(spk["id"])
            speakers_by_id[spk["id"]] = spk
            self.assertIn(spk.get("sourceID"), ("host", "remote"))
            self.assertIsInstance(spk.get("localID"), int)
            self.assertGreaterEqual(spk["localID"], 1)
            self.assertIsInstance(spk.get("displayNumber"), int)
            self.assertGreaterEqual(spk["displayNumber"], 1)
            self.assertNotIn(
                spk["displayNumber"],
                display_numbers,
                "displayNumber must be unique across all speakers in the result",
            )
            display_numbers.add(spk["displayNumber"])

        # Words
        self.assertIsInstance(doc.get("words"), list)
        word_ids = set()
        words_by_id = {}
        for w in doc["words"]:
            self.assertIsInstance(w.get("id"), str)
            self.assertTrue(w["id"])
            self.assertNotIn(w["id"], word_ids, "Duplicate word ID")
            word_ids.add(w["id"])
            words_by_id[w["id"]] = w
            self.assertIn(
                w.get("speakerID"),
                speaker_ids,
                f"Word {w['id']} references unknown speakerID {w.get('speakerID')}",
            )
            self.assertIsInstance(w.get("start"), (int, float))
            self.assertIsInstance(w.get("end"), (int, float))
            self.assertTrue(math.isfinite(w["start"]))
            self.assertTrue(math.isfinite(w["end"]))
            self.assertGreaterEqual(w["start"], 0)
            self.assertLessEqual(w["start"], w["end"])
            self.assertIsInstance(w.get("text"), str)

        # Turns
        self.assertIsInstance(doc.get("turns"), list)
        turn_ids = set()
        assigned_words = set()
        for t in doc["turns"]:
            self.assertIsInstance(t.get("id"), str)
            self.assertTrue(t["id"])
            self.assertNotIn(t["id"], turn_ids, "Duplicate turn ID")
            turn_ids.add(t["id"])
            self.assertIn(t.get("speakerID"), speaker_ids)
            self.assertIsInstance(t.get("start"), (int, float))
            self.assertIsInstance(t.get("end"), (int, float))
            self.assertTrue(math.isfinite(t["start"]))
            self.assertTrue(math.isfinite(t["end"]))
            self.assertGreaterEqual(t["start"], 0)
            self.assertLessEqual(t["start"], t["end"])
            self.assertIsInstance(t.get("wordIDs"), list)
            turn_words = []
            for wid in t["wordIDs"]:
                self.assertIn(wid, word_ids)
                self.assertNotIn(
                    wid,
                    assigned_words,
                    f"Word {wid} is assigned to more than one turn",
                )
                assigned_words.add(wid)
                w = words_by_id[wid]
                turn_words.append(w)
                self.assertEqual(
                    w["speakerID"],
                    t["speakerID"],
                    f"Word {wid} speakerID does not match turn speakerID",
                )

            if turn_words:
                min_w_start = min(w["start"] for w in turn_words)
                max_w_end = max(w["end"] for w in turn_words)
                self.assertLessEqual(t["start"], min_w_start, "Turn start must be <= min word start")
                self.assertGreaterEqual(t["end"], max_w_end, "Turn end must be >= max word end")

        # Every word must belong to exactly one turn
        self.assertEqual(
            word_ids,
            assigned_words,
            "Every word in words must belong to exactly one turn",
        )

        # Baseline words
        self.assertIsInstance(doc.get("baselineWords"), list)
        baseline_ids = set()
        for bw in doc["baselineWords"]:
            self.assertIsInstance(bw.get("id"), str)
            self.assertTrue(bw["id"], "baselineWord ID must be non-empty string")
            self.assertNotIn(bw["id"], baseline_ids, "Duplicate baselineWord ID")
            baseline_ids.add(bw["id"])
            self.assertIn(bw.get("speakerID"), speaker_ids)
            self.assertIsInstance(bw.get("start"), (int, float))
            self.assertIsInstance(bw.get("end"), (int, float))
            self.assertTrue(math.isfinite(bw["start"]))
            self.assertTrue(math.isfinite(bw["end"]))
            self.assertGreaterEqual(bw["start"], 0)
            self.assertLessEqual(bw["start"], bw["end"])
            self.assertIsInstance(bw.get("text"), str)

        # AEC
        self.assertIsInstance(doc.get("aec"), dict)
        self.assertIsInstance(doc["aec"].get("requested"), bool)
        self.assertIn(
            doc["aec"].get("outcome"),
            ("disabled", "applied", "bypassed", "failed"),
        )

        # Playback
        self.assertIsInstance(doc.get("playback"), dict)
        self.assertIn(doc["playback"].get("status"), ("ready", "unavailable"))
        if doc["playback"]["status"] == "ready":
            self.assertIsInstance(doc["playback"].get("mixPath"), str)
            self.assertTrue(doc["playback"]["mixPath"])
            self.assertFalse(doc["playback"]["mixPath"].startswith(".."))
            self.assertFalse(doc["playback"]["mixPath"].startswith("/"))
        else:
            self.assertIsNone(doc["playback"].get("mixPath"))

        # Warnings
        self.assertIsInstance(doc.get("warnings"), list)
        for warn in doc["warnings"]:
            self.assertIsInstance(warn.get("code"), str)
            self.assertIn(warn.get("sourceID"), ("host", "remote", None))
            self.assertIsInstance(warn.get("message"), str)
            self.assertNotIn(
                "/Users/", warn["message"], "Warning message leaked user home path"
            )

        # Context (key is required; nullable or object with optional fields)
        self.assertIn("context", doc, "document must contain 'context' key (object or null)")
        context = doc.get("context")
        if context is not None:
            self.assertIsInstance(context, dict)
            for key in ("title", "startAt", "timeZone", "agenda"):
                if key in context:
                    self.assertIsInstance(context[key], str)
            if "attendees" in context:
                self.assertIsInstance(context["attendees"], list)
                self.assertTrue(all(isinstance(a, str) for a in context["attendees"]))

    def test_recording_generates_structured_document_parakeet_off(self):
        """Parakeet off: pipeline creates result.json with exact baseline and final words matching input."""
        with tempfile.TemporaryDirectory() as directory:
            base, _, _ = self.make_recording_dir(directory)
            host_words = [
                {"start": 0.5, "end": 1.0, "text": "Добрый", "speaker": 1},
                {"start": 1.1, "end": 1.6, "text": "день", "speaker": 1},
            ]
            remote_words = [
                {"start": 2.0, "end": 2.5, "text": "Привет", "speaker": 1}
            ]

            host_data = self.mock_transcribe_data(
                host_words, status="enabled (1 speakers)", speakers_count=1
            )
            remote_data = self.mock_transcribe_data(
                remote_words, status="enabled (1 speakers)", speakers_count=1
            )

            mock_transcribe = unittest.mock.Mock(side_effect=[host_data, remote_data])
            patches = [patch.object(MODULE, "transcribe_file", mock_transcribe)]
            results, _ = self.run_recording_pipeline(base, patches=patches, mock_transcribe=mock_transcribe)

            # Structured result.json assertion (expected RED until task 1.2c publishes it)
            self.assertTrue(
                results,
                "Structured transcript document result.json was not created by recording pipeline",
            )
            self.assertEqual(len(results), 1, "Expected exactly one published result.json")

            result_doc = json.loads(results[0].read_text(encoding="utf-8"))
            self.assert_document_semantics(result_doc)

            # Exact semantic comparison with input
            for src in result_doc["sources"]:
                self.assertEqual(src["correctionStatus"], "disabled")

            speakers_by_source = {
                (s["sourceID"], s["localID"]): s for s in result_doc["speakers"]
            }
            host_spk = speakers_by_source[("host", 1)]
            remote_spk = speakers_by_source[("remote", 1)]
            self.assertEqual(host_spk["displayNumber"], 1)
            self.assertEqual(remote_spk["displayNumber"], 2)

            # Words exact check
            expected_words = [
                ("Добрый", 0.5, 1.0, host_spk["id"]),
                ("день", 1.1, 1.6, host_spk["id"]),
                ("Привет", 2.0, 2.5, remote_spk["id"]),
            ]
            actual_words = [
                (w["text"], w["start"], w["end"], w["speakerID"]) for w in result_doc["words"]
            ]
            self.assertEqual(actual_words, expected_words)

            actual_baseline = [
                (bw["text"], bw["start"], bw["end"], bw["speakerID"]) for bw in result_doc["baselineWords"]
            ]
            self.assertEqual(actual_baseline, expected_words)
            self.assertFalse(result_doc["aec"]["requested"])

    def test_recording_generates_structured_document_parakeet_on(self):
        """Parakeet on: result.json contains exact GigaAM baseline and Parakeet words per source."""
        with tempfile.TemporaryDirectory() as directory:
            base, _, _ = self.make_recording_dir(directory)
            host_gigaam = [{"start": 0.5, "end": 1.2, "text": "питон", "speaker": 1}]
            host_corrected = [{"start": 0.5, "end": 1.2, "text": "Python", "speaker": 1}]
            remote_words = [{"start": 2.0, "end": 2.5, "text": "понятно", "speaker": 1}]

            host_data = self.mock_transcribe_data(
                host_corrected,
                gigaam_segments=host_gigaam,
                status="enabled (1 speakers)",
                speakers_count=1,
                enhancement="enabled (1 replacements, 0 suggestions retained in journal)",
            )
            # Realistic: both sources run with enhancement enabled when Parakeet is requested
            remote_data = self.mock_transcribe_data(
                remote_words,
                gigaam_segments=remote_words,
                status="enabled (1 speakers)",
                speakers_count=1,
                enhancement="enabled (0 replacements, 0 suggestions retained in journal)",
            )

            mock_transcribe = unittest.mock.Mock(side_effect=[host_data, remote_data])
            patches = [patch.object(MODULE, "transcribe_file", mock_transcribe)]
            results, _ = self.run_recording_pipeline(
                base, extra_args=["--parakeet"], patches=patches, mock_transcribe=mock_transcribe
            )

            self.assertTrue(
                results,
                "Structured transcript document result.json was not created by recording pipeline",
            )
            self.assertEqual(len(results), 1, "Expected exactly one published result.json")

            result_doc = json.loads(results[0].read_text(encoding="utf-8"))
            self.assert_document_semantics(result_doc)

            # Both sources completed enhancement
            host_source = next(s for s in result_doc["sources"] if s["id"] == "host")
            remote_source = next(s for s in result_doc["sources"] if s["id"] == "remote")
            self.assertEqual(host_source["correctionStatus"], "completed")
            self.assertEqual(remote_source["correctionStatus"], "completed")

            # Exact text baseline/final verification per source using opaque IDs
            host_words = [w["text"] for w in self.source_items(result_doc, "words", "host")]
            host_baseline = [bw["text"] for bw in self.source_items(result_doc, "baselineWords", "host")]
            self.assertEqual(host_words, ["Python"])
            self.assertEqual(host_baseline, ["питон"])

            remote_words_out = [w["text"] for w in self.source_items(result_doc, "words", "remote")]
            remote_baseline_out = [bw["text"] for bw in self.source_items(result_doc, "baselineWords", "remote")]
            self.assertEqual(remote_words_out, ["понятно"])
            self.assertEqual(remote_baseline_out, ["понятно"])

    def test_recording_generates_structured_document_partial_correction_failure(self):
        """Partial correction failure: failed source retains GigaAM text, successful source corrects."""
        with tempfile.TemporaryDirectory() as directory:
            base, _, _ = self.make_recording_dir(directory)
            host_gigaam = [{"start": 0.5, "end": 1.2, "text": "питон", "speaker": 1}]
            host_corrected = [{"start": 0.5, "end": 1.2, "text": "Python", "speaker": 1}]
            remote_words = [{"start": 1.5, "end": 2.0, "text": "сервер", "speaker": 1}]

            host_data = self.mock_transcribe_data(
                host_corrected,
                gigaam_segments=host_gigaam,
                status="enabled (1 speakers)",
                speakers_count=1,
                enhancement="enabled (1 replacements, 0 suggestions retained in journal)",
            )
            remote_data = self.mock_transcribe_data(
                remote_words,
                gigaam_segments=remote_words,
                status="enabled (1 speakers)",
                speakers_count=1,
                enhancement="failed; original GigaAM retained",
                warnings=["Parakeet не выполнен на системной дорожке"],
            )

            mock_transcribe = unittest.mock.Mock(side_effect=[host_data, remote_data])
            patches = [patch.object(MODULE, "transcribe_file", mock_transcribe)]
            results, _ = self.run_recording_pipeline(
                base, extra_args=["--parakeet"], patches=patches, mock_transcribe=mock_transcribe
            )

            self.assertTrue(
                results,
                "Structured transcript document result.json was not created by recording pipeline",
            )
            self.assertEqual(len(results), 1, "Expected exactly one published result.json")

            result_doc = json.loads(results[0].read_text(encoding="utf-8"))
            self.assert_document_semantics(result_doc)

            host_src = next(s for s in result_doc["sources"] if s["id"] == "host")
            remote_src = next(s for s in result_doc["sources"] if s["id"] == "remote")
            self.assertEqual(host_src["correctionStatus"], "completed")
            self.assertEqual(remote_src["correctionStatus"], "failed")

            # Host applied correction
            host_words = [w["text"] for w in self.source_items(result_doc, "words", "host")]
            host_base = [bw["text"] for bw in self.source_items(result_doc, "baselineWords", "host")]
            self.assertEqual(host_words, ["Python"])
            self.assertEqual(host_base, ["питон"])

            # Remote fell back to GigaAM baseline
            remote_words_out = [w["text"] for w in self.source_items(result_doc, "words", "remote")]
            remote_base = [bw["text"] for bw in self.source_items(result_doc, "baselineWords", "remote")]
            self.assertEqual(remote_words_out, ["сервер"])
            self.assertEqual(remote_base, ["сервер"])

            # Warning recorded for remote
            remote_warnings = [
                w for w in result_doc["warnings"] if w.get("sourceID") == "remote"
            ]
            self.assertTrue(remote_warnings, "Warning for remote failure must be preserved")

    def test_recording_generates_structured_document_overlapping_speech_and_distinct_speaker_identities(self):
        """Overlapping speech: preserve exact intervals and map displayNumbers 1, 2, 3, 4."""
        with tempfile.TemporaryDirectory() as directory:
            base, _, _ = self.make_recording_dir(directory)
            host_words = [
                {"start": 1.0, "end": 2.0, "text": "Давайте", "speaker": 1},
                {"start": 3.0, "end": 3.8, "text": "Второй", "speaker": 2},
            ]
            remote_words = [
                {"start": 1.5, "end": 2.5, "text": "Слушаем", "speaker": 1},
                {"start": 3.2, "end": 4.0, "text": "Четвёртый", "speaker": 2},
            ]

            host_data = self.mock_transcribe_data(
                host_words, status="enabled (2 speakers)", speakers_count=2
            )
            remote_data = self.mock_transcribe_data(
                remote_words, status="enabled (2 speakers)", speakers_count=2
            )

            mock_transcribe = unittest.mock.Mock(side_effect=[host_data, remote_data])
            patches = [patch.object(MODULE, "transcribe_file", mock_transcribe)]
            results, _ = self.run_recording_pipeline(base, patches=patches, mock_transcribe=mock_transcribe)

            self.assertTrue(
                results,
                "Structured transcript document result.json was not created by recording pipeline",
            )
            self.assertEqual(len(results), 1, "Expected exactly one published result.json")

            result_doc = json.loads(results[0].read_text(encoding="utf-8"))
            self.assert_document_semantics(result_doc)

            # Verify speakers are 4 and mapping of displayNumbers: host 1,2 -> 1,2; remote 1,2 -> 3,4
            speakers_by_source_local = {
                (s["sourceID"], s["localID"]): s for s in result_doc["speakers"]
            }
            self.assertEqual(speakers_by_source_local[("host", 1)]["displayNumber"], 1)
            self.assertEqual(speakers_by_source_local[("host", 2)]["displayNumber"], 2)
            self.assertEqual(speakers_by_source_local[("remote", 1)]["displayNumber"], 3)
            self.assertEqual(speakers_by_source_local[("remote", 2)]["displayNumber"], 4)

            # Check that all overlapping word timestamps are preserved exactly without shifts
            words_by_text = {w["text"]: w for w in result_doc["words"]}
            self.assertEqual((words_by_text["Давайте"]["start"], words_by_text["Давайте"]["end"]), (1.0, 2.0))
            self.assertEqual((words_by_text["Слушаем"]["start"], words_by_text["Слушаем"]["end"]), (1.5, 2.5))
            self.assertEqual((words_by_text["Второй"]["start"], words_by_text["Второй"]["end"]), (3.0, 3.8))
            self.assertEqual((words_by_text["Четвёртый"]["start"], words_by_text["Четвёртый"]["end"]), (3.2, 4.0))

    def test_recording_generates_structured_document_empty_channel_and_unknown_voice_count(self):
        """Empty source (voiceCount 0, no words/turns) and unknown voices (disabled diarization: null)."""
        with tempfile.TemporaryDirectory() as directory:
            base, _, _ = self.make_recording_dir(directory)
            host_words = [{"start": 0.5, "end": 1.0, "text": "Монолог", "speaker": 1}]
            remote_words = []

            # Host: diarization disabled -> status 'disabled (1 speakers)', diarization_speakers=0
            host_data = self.mock_transcribe_data(
                host_words, status="disabled (1 speakers)", speakers_count=0
            )
            # Remote: silence -> status 'no speech detected (1 speakers)', diarization_speakers=0
            remote_data = self.mock_transcribe_data(
                remote_words, status="no speech detected (1 speakers)", speakers_count=0
            )

            mock_transcribe = unittest.mock.Mock(side_effect=[host_data, remote_data])
            patches = [patch.object(MODULE, "transcribe_file", mock_transcribe)]
            results, _ = self.run_recording_pipeline(base, patches=patches, mock_transcribe=mock_transcribe)

            self.assertTrue(
                results,
                "Structured transcript document result.json was not created by recording pipeline",
            )
            self.assertEqual(len(results), 1, "Expected exactly one published result.json")

            result_doc = json.loads(results[0].read_text(encoding="utf-8"))
            self.assert_document_semantics(result_doc)

            host_src = next(s for s in result_doc["sources"] if s["id"] == "host")
            remote_src = next(s for s in result_doc["sources"] if s["id"] == "remote")

            # Host disabled diarization: detectedVoiceCount is null
            self.assertEqual(host_src["diarizationStatus"], "disabled")
            self.assertIsNone(
                host_src["detectedVoiceCount"],
                "When diarization is disabled, detectedVoiceCount must be null",
            )

            # Remote confirmed silence: detectedVoiceCount is 0, no words or turns
            self.assertEqual(remote_src["detectedVoiceCount"], 0)
            remote_words_out = self.source_items(result_doc, "words", "remote")
            remote_turns_out = self.source_items(result_doc, "turns", "remote")
            self.assertEqual(remote_words_out, [], "Empty source must not produce words")
            self.assertEqual(remote_turns_out, [], "Empty source must not produce turns")

    def test_recording_generates_structured_document_journal_failure_fallback_to_baseline(self):
        """Real transcribe_file: OSError on writing corrections.json falls back to GigaAM baseline."""
        with tempfile.TemporaryDirectory() as directory:
            base, host, remote = self.make_recording_dir(directory)

            # Mock only ML model execution boundaries, keeping real transcribe_file orchestration
            def nemotron_mock(path):
                return ([types.SimpleNamespace(start=0.5, end=1.5, speaker=0)], 1)

            def gigaam_mock(path, on_progress=None, keep=None):
                return {"segments": [{"start": 0.5, "end": 1.2, "text": "питон"}], "text": "питон"}

            def parakeet_mock(path, keep, on_progress=None):
                return [{"start": 0.5, "end": 1.2, "text": "Python"}]

            def cascade_mock(segments, donor):
                corr = [{**segments[0], "text": "Python"}]
                sugg = [{"applied": True, "original": "питон", "proposed": "Python", "start": 0.5, "end": 1.2}]
                return corr, sugg

            # Wrap write_transcript to inject OSError specifically when writing host corrections.json
            orig_write = transcribe_lib.write_transcript

            def wrapped_write(path, lines):
                if "host_record" in str(path) and "corrections.json" in str(path):
                    raise OSError("Disk quota exceeded for corrections journal")
                return orig_write(path, lines)

            # Explicitly mock VAD to prevent network/onnx_asr dependencies during real transcribe_file run
            mock_vad_obj = unittest.mock.MagicMock()

            patches = [
                patch.object(transcribe_lib, "run_nemotron_diarization", side_effect=nemotron_mock),
                patch.object(transcribe_lib, "run_gigaam", side_effect=gigaam_mock),
                patch("audio_enhancement.load_vad", return_value=mock_vad_obj),
                patch("audio_enhancement.speech_windows", return_value=[True]),
                patch("audio_enhancement.run_parakeet", side_effect=parakeet_mock),
                patch("term_correction.cascade", side_effect=cascade_mock),
                patch.object(transcribe_lib, "write_transcript", side_effect=wrapped_write),
            ]

            results, merged_txt = self.run_recording_pipeline(base, extra_args=["--parakeet"], patches=patches)

            # 1. Prove that real transcribe_file executed the fallback in the legacy output
            self.assertIn("Warning: Микрофон: Parakeet не выполнен; сохранён исходный текст GigaAM", merged_txt)
            self.assertIn("Speaker 1: питон", merged_txt, "Host must retain baseline GigaAM due to journal failure")
            self.assertIn("Speaker 2: Python", merged_txt, "Remote must apply Parakeet correction")

            # 2. Structured result.json assertion (expected RED until task 1.2c publishes it)
            self.assertTrue(
                results,
                "Structured transcript document result.json was not created by recording pipeline",
            )
            self.assertEqual(len(results), 1, "Expected exactly one published result.json")

            result_doc = json.loads(results[0].read_text(encoding="utf-8"))
            self.assert_document_semantics(result_doc)

            host_src = next(s for s in result_doc["sources"] if s["id"] == "host")
            remote_src = next(s for s in result_doc["sources"] if s["id"] == "remote")
            self.assertEqual(host_src["correctionStatus"], "failed")
            self.assertEqual(remote_src["correctionStatus"], "completed")

            host_words = [w["text"] for w in self.source_items(result_doc, "words", "host")]
            remote_words = [w["text"] for w in self.source_items(result_doc, "words", "remote")]
            self.assertEqual(host_words, ["питон"])
            self.assertEqual(remote_words, ["Python"])

    def test_recording_pipeline_rejects_invalid_input_intervals_before_merge(self):
        """Existing regression baseline: pipeline rejects non-finite, negative, and reversed intervals from ASR.

        Note: Verifies existing production merge_sources behavior on bad ASR data (GREEN),
        distinct from future result.json document validation (task 1.2a).
        """
        with tempfile.TemporaryDirectory() as directory:
            base, _, _ = self.make_recording_dir(directory)
            invalid_cases = [
                ({"start": -1.0, "end": 1.0, "text": "negative", "speaker": 1}, "negative start"),
                ({"start": float("nan"), "end": 1.0, "text": "nan", "speaker": 1}, "NaN timestamp"),
                ({"start": 0.0, "end": float("inf"), "text": "inf", "speaker": 1}, "infinite timestamp"),
                ({"start": 2.0, "end": 1.0, "text": "reversed", "speaker": 1}, "reversed interval (start > end)"),
            ]

            for seg, description in invalid_cases:
                with self.subTest(scenario=description):
                    bad_data = self.mock_transcribe_data([seg])
                    normal_data = self.mock_transcribe_data(
                        [{"start": 0.0, "end": 1.0, "text": "ok", "speaker": 1}]
                    )
                    mock_fn = unittest.mock.Mock(side_effect=[bad_data, normal_data])
                    with self.assertRaises(ValueError):
                        self.run_recording_pipeline(
                            base, patches=[patch.object(MODULE, "transcribe_file", mock_fn)]
                        )


class TestTranscriptDocumentFixturesIntegrity(unittest.TestCase):
    """Integrity and structural verification for shared synthetic fixtures.

    Note: These tests verify the fixture files themselves. They prove that valid fixtures
    meet the v1 design contract and that negative fixtures contain the expected violations.
    These are not a substitute for the upcoming document validator (task 1.2a / 1.3).
    """

    def test_all_valid_fixtures_satisfy_v1_specification(self):
        valid_files = sorted(FIXTURES_DIR.glob("valid_*.json"))
        self.assertGreaterEqual(len(valid_files), 6, "Expected at least 6 valid fixtures")

        gen_tester = TestTranscriptDocumentGeneration()
        for fixture_path in valid_files:
            with self.subTest(fixture=fixture_path.name):
                content = json.loads(fixture_path.read_text(encoding="utf-8"))
                gen_tester.assert_document_semantics(content)

    def test_negative_fixtures_contain_intended_structural_violations(self):
        # 1. Invalid schema version
        doc_version = json.loads((FIXTURES_DIR / "invalid_schema_version.json").read_text())
        self.assertNotEqual(doc_version.get("schemaVersion"), 1)

        # 2. Duplicate IDs
        doc_dup = json.loads((FIXTURES_DIR / "invalid_duplicate_ids.json").read_text())
        word_ids = [w["id"] for w in doc_dup.get("words", [])]
        self.assertNotEqual(len(word_ids), len(set(word_ids)), "Must contain duplicate word IDs")

        # 3. Broken references
        doc_broken = json.loads((FIXTURES_DIR / "invalid_broken_references.json").read_text())
        known_word_ids = {w["id"] for w in doc_broken.get("words", [])}
        referenced_word_ids = {wid for t in doc_broken.get("turns", []) for wid in t.get("wordIDs", [])}
        self.assertTrue(referenced_word_ids - known_word_ids, "Must contain dangling word references")

        # 4. Invalid intervals (start > end)
        doc_intervals = json.loads((FIXTURES_DIR / "invalid_intervals.json").read_text())
        has_invalid = any(w["start"] > w["end"] for w in doc_intervals.get("words", []))
        self.assertTrue(has_invalid, "Must contain words with start > end")

        # 5. Path traversal
        doc_traversal = json.loads((FIXTURES_DIR / "invalid_path_traversal.json").read_text())
        paths = [s["originalAudioPath"] for s in doc_traversal.get("sources", [])] + \
                [s["recognitionAudioPath"] for s in doc_traversal.get("sources", [])]
        self.assertTrue(any(".." in p or p.startswith("/") for p in paths), "Must contain path traversal")


if __name__ == "__main__":
    unittest.main()
