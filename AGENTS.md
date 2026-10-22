# Meeting Companion

Standalone macOS 15+ / Apple Silicon meeting recorder. No agent or skill is
required to record or transcribe. Keep changes small; use existing platform APIs.

## Layout

- `Sources/MeetingCompanionCore`: ScreenCaptureKit / Core Audio Tap audio capture, synchronized source
  WAV files, subprocess transcription.
- `Sources/MeetingCompanionApp`: menu bar UI, permissions/diagnostics, calendar,
  reminders and processing capsule.
- `Sources/MeetingCompanionCLI`: optional recording CLI.
- `transcription/`: GigaAM ONNX speech recognition, Nemotron MLX diarization,
  Silero VAD, optional Parakeet term correction, timestamp merge, runtime/model preparation and Python tests.
- `Resources/Info.plist`, `scripts/`: bundle metadata, build/install and checks.

Before changing transcription or term correction, read
[`docs/transcription-pipeline.md`](docs/transcription-pipeline.md) for the algorithm,
artifact layout, failure behavior and evaluation method.

## Invariants

- Keep `local.meeting-companion` bundle ID and `MeetingCompanion` storage paths
  stable; changing signing identity can reset macOS permissions.
- Never remove user recordings or transcripts. Remove app-owned model/runtime caches
  only through the user-confirmed reset action; preserve shared caches. Reset permissions
  only at the user's explicit request, with `scripts/reset-permissions.sh` after
  the app quits. Never reset permissions automatically during build/install.
- Keep host and remote WAVs on the same timeline: 16 kHz mono PCM16, silence
  included. Host is the microphone source and can contain multiple voices; do not hardcode identities.
- Transcription must work offline after preparation. Never upload audio.
- Merge channels by word timestamps before grouping turns; preserve overlaps.
- New recordings use `YYYY-MM/DD/NAME/`; final transcript, context and mixed audio stay
  there, intermediate files and source audio go in `raw/`. Keep reading legacy flat recordings.
- VAD gates whole existing ASR windows; keep absolute timestamps and original audio.
  Only a detection copy is amplified. Preserve baseline GigaAM text with Parakeet enabled.
- Keep processing UI event-driven and discrete; no continuous animation for transcription.
- On transcription failure keep audio and logs, and allow retry.
- Capture warnings must not block transcription of finalized WAVs. Keep the bounded
  capture report and preserve CAF sources when capture/export has warnings.
- Mute must silence host in both WAV and CAF, using capture timestamps (including
  delayed delivery); remote is unaffected. Level detection never stores muted audio.
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

## Releases

Use SemVer in `Resources/Info.plist`; increment `CFBundleVersion` for a release
build. Record user-visible changes in `CHANGELOG.md` under `[Unreleased]`, then
move them to a dated version section for release. Keep version strings out of code.
