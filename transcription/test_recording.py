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

    def test_new_meeting_sources_use_raw_and_keep_final_transcript_outside(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)/"meeting"
            raw = base.parent/"raw"
            raw.mkdir()
            sources = module.source_paths(base)
            self.assertTrue(all(source.parent == raw for source in sources))
            for source in sources: source.touch()
            data = {**self.data(), "gigaam_segments": []}
            with patch.object(sys, "argv", ["recording", str(base), "--parakeet"]), \
                 patch.object(module, "transcribe_file", return_value=data), \
                 contextlib.redirect_stdout(io.StringIO()):
                module.main()
            self.assertTrue((base.parent/"meeting.sources.transcript.txt").is_file())
            text = (base.parent/"meeting.sources.transcript.txt").read_text()
            self.assertNotIn(directory, text)
            self.assertIn("Host audio: raw/meeting.host_record.wav", text)
            self.assertIn("Remote audio: raw/meeting.remote_record.wav", text)
            self.assertTrue((raw/"meeting.sources.gigaam.transcript.txt").is_file())
            self.assertFalse((base.parent/"meeting.sources.gigaam.transcript.txt").exists())

    def test_capture_warnings_do_not_block_source_transcription(self):
        import json
        for payload in ({'droppedBuffers': 3, 'droppedSourceSeconds': .03, 'failure': 'capture failed', 'exportFailure': 'disk'}, []):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)/'meeting'
                raw = base.parent/'raw'; raw.mkdir()
                for source in module.source_paths(base): source.touch()
                (raw/'meeting.capture-report.json').write_text(json.dumps(payload))
                events = io.StringIO()
                with patch.object(sys, 'argv', ['recording', str(base)]), \
                     patch.object(module, 'transcribe_file', return_value=self.data([self.segment(1,'kept')])) as engine, \
                     contextlib.redirect_stdout(events):
                    module.main()
                self.assertEqual(engine.call_count, 2)
                text = (base.parent/'meeting.sources.transcript.txt').read_text()
                self.assertIn('kept', text)
                self.assertIn('Warning:', text)
                self.assertIn('"stage": "warning"', events.getvalue())

    def test_speaker_limit_warnings_are_near_top_and_source_specific(self):
        host = {**self.data([self.segment(1, "Host")]), "warnings": ["Nemotron достиг лимита 8"]}
        remote = self.data([self.segment(2, "Remote")])
        text = "\n".join(module.merge_sources(host, remote))
        self.assertIn("Warning: Микрофон: Nemotron достиг лимита 8", text)
        self.assertIn("на одной дорожке", text)
        self.assertLess(text.index("Warning:"), text.index("[00:01]"))

    def test_calendar_count_is_a_warning_not_a_measured_voice_count(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)/"meeting"
            context = base.with_name("meeting.context.json")
            self.assertEqual(module.meeting_context_warnings(base), [])
            for count in (7, 8, 12):
                context.write_text(json.dumps({"attendees": [f"Person {i}" for i in range(count)]}))
                warnings = module.meeting_context_warnings(base)
                self.assertEqual(bool(warnings), count >= 8)
                if warnings:
                    self.assertIn("не число реально говоривших", warnings[0])
                    self.assertIn("проверяйте", warnings[0])
            context.write_text("[]")
            self.assertIn("Не удалось проверить", module.meeting_context_warnings(base)[0])

    def test_warnings_survive_final_and_original_transcripts(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)/"meeting"
            raw = base.parent/"raw"; raw.mkdir()
            for source in module.source_paths(base): source.touch()
            base.with_name("meeting.context.json").write_text(json.dumps({"attendees": ["Same name"]*9}))
            (raw/"meeting.capture-report.json").write_text(json.dumps({"microphoneRecoveries": 2, "microphoneMissing": True}))
            words = [self.segment(1, "Kept speech")]
            data = {**self.data(words), "gigaam_segments": words, "warnings": ["Nemotron достиг лимита 8"]}
            with patch.object(sys, "argv", ["recording", str(base), "--parakeet"]), \
                 patch.object(module, "transcribe_file", return_value=data), \
                 contextlib.redirect_stdout(io.StringIO()):
                module.main()
            for output in (base.with_name("meeting.sources.transcript.txt"), raw/"meeting.sources.gigaam.transcript.txt"):
                text = output.read_text()
                header = text.split("[00:01]", 1)[0]
                self.assertIn("участников: 9", header)
                self.assertIn("восстановления микрофона: 2", header)
                self.assertIn("не доказывает молчание", header)
                self.assertIn("Warning: Микрофон: Nemotron достиг лимита 8", header)
                self.assertIn("Warning: Системный звук: Nemotron достиг лимита 8", header)
                self.assertIn("Kept speech", text)

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

    def test_echo_option_routes_only_microphone_and_keeps_progress_and_provenance(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / "meeting"
            host, remote = module.source_paths(base)
            host.touch(); remote.touch()
            processed = host.with_suffix(".aec.wav"); processed.touch()
            events = io.StringIO()
            def echo(source, reference, progress):
                self.assertEqual((source, reference), (host, remote))
                progress(8000, 32000); progress(32000, 32000)
                return processed
            with patch.object(sys, "argv", ["recording", str(base), "--echo-cancel"]), \
                 patch.object(module, "cancel_echo", side_effect=echo), \
                 patch.object(module, "transcribe_file", return_value=self.data()) as engine, \
                 contextlib.redirect_stdout(events):
                module.main()
            self.assertEqual([call.args[0] for call in engine.call_args_list], [processed, remote])
            header = base.with_name("meeting.sources.transcript.txt").read_text()
            self.assertIn("Host audio: meeting.host_record.wav", header)
            self.assertIn("Microphone processing: WebRTC AEC3 (beta); meeting.host_record.aec.wav", header)
            self.assertNotIn(directory, header)
            values = [json.loads(line.removeprefix("MEETING_PROGRESS ")) for line in events.getvalue().splitlines()
                      if line.startswith("MEETING_PROGRESS ")]
            self.assertEqual(values[0]["stage"], "echo")
            self.assertTrue(all(value["completed"] <= value["total"] for value in values))
            self.assertEqual(values[-1]["step"], 10)

    def test_echo_failure_falls_back_and_is_visible_in_final_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / "meeting"
            for source in module.source_paths(base): source.touch()
            for error in (RuntimeError("native failed"), module.wave.Error("invalid WAV")):
                with self.subTest(error=error), \
                     patch.object(sys, "argv", ["recording", str(base), "--echo-cancel"]), \
                     patch.object(module, "cancel_echo", side_effect=error), \
                     patch.object(module, "transcribe_file", return_value=self.data()) as engine, \
                     contextlib.redirect_stdout(io.StringIO()):
                    module.main()
                self.assertEqual([call.args[0] for call in engine.call_args_list], list(module.source_paths(base)))
                self.assertIn("Эхоподавление не выполнено", base.with_name("meeting.sources.transcript.txt").read_text())


if __name__ == "__main__":
    unittest.main()
