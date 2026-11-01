import contextlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_transcript_document import MODULE, create_synthetic_wav


class PublicationTests(unittest.TestCase):
    def test_aec_bypass_and_failure_record_actual_source(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as folder:
                base = Path(folder) / "meeting"
                host, remote = MODULE.source_paths(base)
                for path in (host, remote):
                    create_synthetic_wav(path)
                with patch.object(MODULE, "cancel_echo", return_value=host,
                                  side_effect=RuntimeError("AEC failed") if fail else None):
                    self.run_recording(base, args=["--echo-cancel"])
                doc = json.loads(next(base.parent.glob("raw/transcripts/*/result.json")).read_text())
                self.assertEqual(doc["aec"], dict(requested=True, outcome="failed" if fail else "bypassed"))
                self.assertEqual(doc["sources"][0]["recognitionAudioPath"], host.name)
                self.assertEqual(doc["playback"]["status"], "ready")
                if fail:
                    self.assertTrue(any("Эхоподавление" in w["message"] for w in doc["warnings"]))

    def run_recording(self, base, **kwargs):
        data = dict(segments=[dict(start=0, end=.5, text="Текст", speaker=1)],
                    gigaam_segments=[dict(start=0, end=.5, text="Текст", speaker=1)],
                    diarization="Diarization: enabled (1 speakers)", diarization_speakers=1)
        with patch("sys.argv", ["recording", str(base), *kwargs.get("args", [])]), \
             patch.object(MODULE, "transcribe_file", return_value=data), \
             contextlib.redirect_stdout(io.StringIO()):
            MODULE.main()

    def test_publication_is_atomic_and_interruption_preserves_previous_version(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "meeting"
            for path in MODULE.source_paths(base):
                create_synthetic_wav(path)
            self.run_recording(base)
            versions = base.parent / "raw/transcripts"
            published = list(versions.glob("*/result.json"))
            self.assertEqual(len(published), 1, "Successful recognition must publish one version")
            previous = published[0]
            before = previous.read_bytes()
            edits = previous.with_name("edits.json")
            edits.write_text('{"sentinel": "user edits"}')

            def interrupted(staging, destination):
                self.assertTrue((staging / "result.json").is_file())
                self.assertEqual(list(versions.glob("*/result.json")), [previous])
                self.assertFalse(destination.exists())
                raise KeyboardInterrupt("interrupted before publication")

            with patch.object(Path, "rename", interrupted), self.assertRaises(KeyboardInterrupt):
                self.run_recording(base)
            self.assertEqual(list(versions.glob("*/result.json")), [previous])
            self.assertEqual(previous.read_bytes(), before)

            self.assertEqual(edits.read_text(), '{"sentinel": "user edits"}')
            self.run_recording(base)
            self.assertEqual(len(list(versions.glob("*/result.json"))), 2)
            self.assertEqual(previous.read_bytes(), before)

    def test_process_death_leaves_staging_outside_available_versions(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "meeting"
            for path in MODULE.source_paths(base):
                create_synthetic_wav(path)
            script = '''
import os
from pathlib import Path
from unittest.mock import patch
from test_transcript_publication import PublicationTests
def stop(staging, destination):
    assert (staging / "result.json").is_file()
    os._exit(73)
with patch.object(Path, "rename", stop):
    PublicationTests().run_recording(Path(__import__("sys").argv[1]))
'''
            child = subprocess.run([sys.executable, "-B", "-c", script, str(base)],
                                   cwd=Path(__file__).parent, capture_output=True)
            self.assertEqual(child.returncode, 73, child.stderr.decode())
            self.assertTrue(list(base.parent.glob("raw/.transcript-*/result.json")))
            self.assertEqual(list(base.parent.glob("raw/transcripts/*/result.json")), [])
            self.run_recording(base)
            self.assertEqual(len(list(base.parent.glob("raw/transcripts/*/result.json"))), 1)

    def test_mix_failure_keeps_text_and_calendar_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "meeting"
            for path in MODULE.source_paths(base):
                create_synthetic_wav(path)
            context = dict(summary="Встреча", start="2026-10-30T10:00:00Z",
                           timezone="Europe/Moscow", agenda="План", attendees=["Алиса"])
            base.with_suffix(".context.json").write_text(json.dumps(context))
            with patch("transcript_mix.prepare_mix", side_effect=OSError("/private/example failed")):
                self.run_recording(base)
            doc = json.loads(next(base.parent.glob("raw/transcripts/*/result.json")).read_text())
            self.assertEqual(doc["playback"], dict(status="unavailable", mixPath=None))
            self.assertEqual(doc["words"][0]["text"], "Текст")
            self.assertEqual(doc["context"], dict(title="Встреча", startAt=context["start"],
                             timeZone=context["timezone"], agenda="План", attendees=["Алиса"]))
            self.assertTrue(any(w["code"] == "playback_mix_failed" for w in doc["warnings"]))
            self.assertNotIn("/private/", json.dumps(doc))

    def test_encoder_process_failure_publishes_text_without_a_mix(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "meeting"
            for path in MODULE.source_paths(base):
                create_synthetic_wav(path)
            with patch("transcript_mix.subprocess.run", side_effect=subprocess.CalledProcessError(1, "afconvert")):
                self.run_recording(base)
            doc = json.loads(next(base.parent.glob("raw/transcripts/*/result.json")).read_text())
            self.assertEqual(doc["playback"], dict(status="unavailable", mixPath=None))
            self.assertTrue(doc["words"])

    def test_aec_source_is_frozen_and_retry_does_not_change_old_mix(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "meeting"
            host, remote = MODULE.source_paths(base)
            for path in (host, remote):
                create_synthetic_wav(path)
            processed = host.with_suffix(".aec.wav")
            create_synthetic_wav(processed)
            with patch.object(MODULE, "cancel_echo", return_value=processed):
                self.run_recording(base, args=["--echo-cancel"])
            result = next(base.parent.glob("raw/transcripts/*/result.json"))
            doc = json.loads(result.read_text())
            self.assertEqual(doc["aec"], dict(requested=True, outcome="applied"))
            frozen = base.parent / doc["sources"][0]["recognitionAudioPath"]
            self.assertEqual(frozen.read_bytes(), processed.read_bytes())
            self.assertEqual(doc["playback"]["status"], "ready")
            mix = base.parent / doc["playback"]["mixPath"]
            saved_mix = mix.read_bytes()
            processed.write_bytes(b"new working copy")
            self.run_recording(base)
            self.assertEqual(mix.read_bytes(), saved_mix)
            self.assertEqual(frozen.read_bytes(), host.read_bytes())
