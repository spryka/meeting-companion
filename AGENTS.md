# Meeting Companion

Standalone macOS 15+ / Apple Silicon meeting recorder. No agent or skill is
required to record or transcribe. Keep changes small; use existing platform APIs.

## Layout

- `Sources/MeetingCompanionCore`: ScreenCaptureKit capture, synchronized source
  WAV files, subprocess transcription.
- `Sources/MeetingCompanionApp`: menu bar UI, permissions/diagnostics, calendar,
  reminders and completion notifications.
- `Sources/MeetingCompanionCLI`: optional recording CLI.
- `transcription/`: GigaAM ONNX speech recognition, Nemotron MLX diarization,
  timestamp merge, runtime/model preparation and Python tests.
- `Resources/Info.plist`, `scripts/`: bundle metadata, build/install and checks.

## Invariants

- Keep `local.meeting-companion` bundle ID and `MeetingCompanion` storage paths
  stable; changing signing identity can reset macOS permissions.
- Never remove user recordings, transcripts or model caches. Reset permissions
  only at the user's explicit request, with `scripts/reset-permissions.sh` after
  the app quits. Never reset permissions automatically during build/install.
- Keep host and remote WAVs on the same timeline: 16 kHz mono PCM16, silence
  included. Host is the microphone owner; do not hardcode a person's name.
- Transcription must work offline after preparation. Never upload audio.
- Merge channels by word timestamps before grouping turns; preserve overlaps.
- On transcription failure keep audio and logs, and allow retry.
- Do not quit/install over an active recording, preparation or transcription.
- Do not commit certificates/keys, `.codesign/`, `.build/`, `dist/`, recordings,
  calendar exports or machine-specific paths. No skill dependencies in the app.

## Validation

Run `swift build -c release`, then Python tests:

```sh
uv run --quiet --python 3.12 --with numpy --with soundfile python -B -m unittest discover -s transcription -p 'test_*.py' -q
```

For packaging run `./scripts/build-app.sh`; it validates bundle metadata,
resources and signatures. Relevant Swift self-check commands are in README.
Describe any UI, recording or permission flows you did not exercise.
