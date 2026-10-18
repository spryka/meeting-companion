import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import plistlib

spec = importlib.util.spec_from_file_location('finder', Path(__file__).with_name('find-recording.py'))
finder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(finder)


class FinderTests(unittest.TestCase):
    def test_preferences_are_optional_and_custom_root_is_respected(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(Path, 'home', return_value=Path(directory)):
            home = Path(directory)
            self.assertEqual(finder.recordings_root(), home/'Downloads/Meetings')
            preferences = home/'Library/Preferences/local.meeting-companion.plist'
            preferences.parent.mkdir(parents=True)
            preferences.write_bytes(plistlib.dumps({}))
            self.assertEqual(finder.recordings_root(), home/'Downloads/Meetings')
            preferences.write_bytes(plistlib.dumps({'recordingsDirectory': str(home/'custom')}))
            self.assertEqual(finder.recordings_root(), home/'custom')

    def test_newest_unfinished_recording_wins_over_older_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            day = root/'2026-10/18'
            day.mkdir(parents=True)
            (day/'meeting_2026-10-18_10-00-00.sources.transcript.txt').touch()
            name = 'meeting_2026-10-18_11-00-00'
            raw = day/name/'raw'
            raw.mkdir(parents=True)
            (raw/(name+'.transcription.log')).touch()
            # Experiments and modification times must not affect latest selection.
            (day/'experiments').mkdir()
            (day/'experiments/meeting_2099-01-01_00-00-00.sources.transcript.txt').touch()
            result = finder.latest(root)
            self.assertFalse(result['ready'])
            self.assertEqual(result['recording'], str(day/name/name))
            self.assertEqual(result['log'], str(raw/(name+'.transcription.log')))

    def test_legacy_flat_transcript_and_empty_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                finder.latest(root)
            day = root/'2026-10/16'
            day.mkdir(parents=True)
            path = day/'meeting_2026-10-16_11-30-00.sources.transcript.txt'
            path.touch()
            result = finder.latest(root)
            self.assertTrue(result['ready'])
            self.assertEqual(result['transcript'], str(path))


if __name__ == '__main__':
    unittest.main()
