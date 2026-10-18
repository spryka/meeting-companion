"""Locate the latest recording without loading transcripts or contacting calendars."""
import argparse
import json
from pathlib import Path
import plistlib
import re


def recordings_root():
    preferences = Path.home() / 'Library/Preferences/local.meeting-companion.plist'
    if preferences.is_file():
        with preferences.open('rb') as stream:
            configured = plistlib.load(stream).get('recordingsDirectory')
        if configured:
            return Path(configured).expanduser()
    return Path.home() / 'Downloads/Meetings'


def latest(root):
    candidates = set()
    for day in root.glob('20[0-9][0-9]-[0-9][0-9]/[0-9][0-9]'):
        for entry in day.iterdir():
            if entry.is_dir() and re.fullmatch(r'meeting_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}', entry.name):
                candidates.add(entry / entry.name)
            elif entry.is_file() and re.fullmatch(r'meeting_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:\.m4a|\.sources\.transcript\.txt)', entry.name):
                candidates.add(entry.with_name(entry.name.split('.', 1)[0]))
    if not candidates:
        raise FileNotFoundError(f'No recordings in {root}')
    base = max(candidates, key=lambda path: path.name)
    log = base.parent / 'raw' / (base.name + '.transcription.log')
    if not log.is_file():
        log = base.with_name(base.name + '.transcription.log')
    transcript = base.with_name(base.name + '.sources.transcript.txt')
    return dict(recording=str(base), transcript=str(transcript), ready=transcript.is_file(),
                context=str(base.with_name(base.name + '.context.json')), log=str(log))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(latest(args.root if args.root is not None else recordings_root()), ensure_ascii=False))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, str(error) + '\n')
