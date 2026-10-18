import importlib.util
import contextlib
import io
import os
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("recording", Path(__file__).with_name("transcribe-recording.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecordingTests(unittest.TestCase):
    def data(self, segments=(), status="enabled (2 speakers)"):
        return {"segments": list(segments), "diarization": "Diarization: " + status}

    def segment(self, start, text, speaker=1):
        return {"start": start, "end": start + 0.1, "text": text, "speaker": speaker}

    def test_recorder_only_uses_wav_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "recording"
            old = tuple(Path(str(base) + f".{source}_record.m4a") for source in ("host", "remote"))
            for path in old:
                path.touch()
            self.assertEqual(module.source_paths(base), tuple(path.with_suffix(".wav") for path in old))
            new = tuple(path.with_suffix(".wav") for path in old)
            for path in new:
                path.touch()
            self.assertEqual(module.source_paths(base), new)

    def test_overlap_and_multiple_remote_voices(self):
        host = self.data([self.segment(13, "Host interruption"), self.segment(3601, "Later")])
        remote = self.data([self.segment(11, "Remote"), self.segment(13, "Other", 2)])
        lines = module.merge_sources(host, remote)
        turns = [line for line in lines if line.startswith("[")]
        self.assertEqual(turns, ["[00:11] Speaker 2: Remote", "[00:13] Speaker 1: Host interruption",
                                 "[00:13] Speaker 3: Other", "[1:00:01] Speaker 1: Later"])

    def test_failed_and_silent_remote_are_not_invented_voices(self):
        failed = self.data([self.segment(0, "Text")], "failed (1 speakers)")
        lines = module.merge_sources(self.data(), failed)
        self.assertTrue(any("placeholder" in line for line in lines))
        silent = self.data([self.segment(0, "")], "failed (1 speakers)")
        self.assertFalse(any(line.startswith("Speaker 2:") for line in module.merge_sources(self.data(), silent)))

    def test_invalid_remote_status_and_timestamp_are_rejected(self):
        for remote in ({"segments": []}, self.data([self.segment(float("nan"), "Text")]),
                       self.data([self.segment(-1, "Text")])):
            with self.assertRaises(ValueError):
                module.merge_sources(self.data(), remote)

    def test_monologue_splits_at_interruption_with_subsecond_precision(self):
        host = self.data([self.segment(5.25, "Мой"), self.segment(5.9, "комментарий")])
        remote = self.data([self.segment(0, "Лекция"), self.segment(1, "началась"),
                            self.segment(5.1, "до"), self.segment(5.3, "после"),
                            self.segment(6.1, "продолжилась")])
        turns = [line for line in module.merge_sources(host, remote) if line.startswith("[")]
        self.assertEqual(turns, ["[00:00] Speaker 2: Лекция началась", "[00:05] Speaker 2: до",
                                "[00:05] Speaker 1: Мой комментарий",
                                "[00:05] Speaker 2: после продолжилась"])

    def test_five_minute_monologue_keeps_every_word_in_short_paragraphs(self):
        remote = self.data([self.segment(second, str(second)) for second in range(300)])
        lines = [line for line in module.merge_sources(self.data(), remote) if line.startswith("[")]
        self.assertEqual(len(lines), 20)
        self.assertEqual(" ".join(line.split(": ", 1)[1] for line in lines), " ".join(map(str, range(300))))

    def test_recording_uses_shared_pipeline_and_emits_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "recording"
            for source in module.source_paths(base):
                source.touch()
            calls = []
            def transcribe(source, output, *, vad, parakeet, on_progress, on_warning):
                self.assertEqual(os.environ.get("HF_HUB_OFFLINE"), "1")
                self.assertTrue(vad)
                diarize = "remote" in source.name
                calls.append((source, vad))
                on_progress("gigaam", 1, 2)
                return self.data([self.segment(0 if diarize else 5, "Remote" if diarize else "Host")],
                                 "enabled (1 speakers)" if diarize else "disabled (1 speakers)")
            output = io.StringIO()
            with patch.object(sys, "argv", ["transcribe-recording", "--offline", str(base)]), \
                 patch.object(module, "transcribe_file", side_effect=transcribe), \
                 patch.dict(os.environ), contextlib.redirect_stdout(output):
                module.main()
            text = base.with_name("recording.sources.transcript.txt").read_text()
            self.assertIn("[00:00] Speaker 2: Remote\n[00:05] Speaker 1: Host", text)
            self.assertEqual(calls, list(zip(module.source_paths(base.resolve()), (True, True))))
            self.assertIn('"channel": "host"', output.getvalue())
            self.assertIn('"channel": "remote"', output.getvalue())
            self.assertIn('"stage": "merge", "completed": 1', output.getvalue())

    def test_two_microphone_voices_remain_distinct_from_remote(self):
        host = self.data([self.segment(0, "First", 1), self.segment(2, "Second", 2)])
        remote = self.data([self.segment(1, "Remote", 1), self.segment(3, "Other", 2)])
        lines = module.merge_sources(host, remote)
        self.assertEqual([line for line in lines if line.startswith("[")], [
            "[00:00] Speaker 1: First", "[00:01] Speaker 3: Remote",
            "[00:02] Speaker 2: Second", "[00:03] Speaker 4: Other"])
        self.assertIn("Speaker 2: Host / microphone source, Nemotron voice; identity unverified.", lines)

    def test_source_failure_preserves_existing_merge_and_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "recording"
            for source in module.source_paths(base):
                source.write_bytes(b"original")
            merged = base.with_name("recording.sources.transcript.txt")
            merged.write_text("previous")
            with patch.object(sys, "argv", ["transcribe-recording", str(base)]), \
                 patch.object(module, "transcribe_file", side_effect=[self.data(), RuntimeError("failure")]):
                with self.assertRaises(RuntimeError):
                    module.main()
            self.assertEqual(merged.read_text(), "previous")
            self.assertTrue(all(source.read_bytes() == b"original" for source in module.source_paths(base)))


if __name__ == "__main__":
    unittest.main()
