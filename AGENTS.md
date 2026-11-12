# Meeting Companion

Standalone Swift 6 application for macOS 15+ on Apple Silicon. UI uses SwiftUI
and AppKit; local recognition runs in an isolated Swift/MLX worker. Recording
and transcription are complete app features, with no external agent or skill dependency.
Keep changes small; use existing platform APIs.

## Technology stack

- Implement application logic and tests in Swift. Use the existing shell scripts
  for build, packaging and checks; WebRTC AEC remains native C++.
- Keep MLX/model ownership in MeetingTranscriptionPipeline and
  MeetingTranscriptionWorker. App and CLI use shared application services and
  the native worker protocol, without importing MLX or the pipeline.
- Extend the existing native app and offline pipeline. A different runtime,
  service or UI stack is an architectural change requiring explicit agreement.
- Use full Xcode through DEVELOPER_DIR and its installed Metal Toolchain;
  select TOOLCHAINS when needed instead of changing global xcode-select.

## Development workflow

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for SDD, TDD, review and exceptions.
Before behavior, data-format or contract changes, read relevant OpenSpec specs
and active changes, then prepare and review proposal, scenarios, design and tasks.
Use the project-local intent-driven schema. Read in-force root adr/ decisions and
complete each change ADR review before tasks. New ADR acceptance requires maintainer
agreement; accepted architecture does not mean shipped behavior. Never rewrite an
accepted ADR; supersede it with a new record.
Active changes describe proposed behavior, not evidence of shipped features.
Use test-first development for testable logic and regression fixes. Confirm the
expected failure before implementation. Record justified exceptions and manual UAT.
Validate with `openspec validate <name> --strict`; mark tasks done only after
verification. Do not archive unimplemented or unverified changes.
Keep requirements in specs and rationale in design/context. Trivial documentation
and behavior-preserving changes do not need a new specification.

## Layout

- `Sources/MeetingCompanionCore`: Foundation contracts, progress, recording paths,
  transcript storage and existing editor components.
- `Sources/MeetingCompanionApplication`: shared recording, processing and history services.
- `Sources/MeetingCompanionPlatform`: ScreenCaptureKit / Core Audio Tap audio capture,
  synchronized source WAV files, native worker subprocess and AVPlayer transport.
- `Sources/MeetingCompanionApp`: menu bar UI, permissions/diagnostics, calendar,
  reminders and processing capsule.
- `Sources/MeetingCompanionCLI`: optional recording CLI.
- `Sources/MeetingTranscriptionPipeline` and `Sources/MeetingTranscriptionWorker`: native Swift/MLX recognition, diarization, term correction and model preparation.
- `Sources/WebRTCAEC`: native C++ echo canceller; shell build preserves pinned WebRTC.
- `Tests/Fixtures`: synthetic transcript JSON shared by Swift tests and editor checks.
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
  there, intermediate files and source audio go in `raw/`. Full functionality requires
  canonical folder basename == recording stem (standard since 1.4.0). Legacy flat
  placement is list + contained saved TXT read-only; never process or write it.
- Nemotron speech intervals gate whole existing ASR windows; keep absolute timestamps and original audio.
  Gate windows by existing Nemotron intervals; unavailable/empty diarization admits all windows.
  Preserve baseline GigaAM text with Parakeet enabled.
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

Run `swift build -c release`, `swift test`, then:

```sh
bash scripts/check-module-boundaries.sh
swift skills/local-audio-transcriber/scripts/find-recording.swift --self-test
```

Python and uv are not required. The old pipeline remains in Git at
`research/swift-mlx-pipeline` (`56cf8a3`), not in the current source tree.

For packaging run `./scripts/build-app.sh`; it validates bundle metadata,
resources and signatures. Relevant Swift self-check commands are in README.
Describe any UI, recording or permission flows you did not exercise.

## Releases

Use SemVer in `Resources/Info.plist`; increment `CFBundleVersion` for a release
build. Record user-visible changes in `CHANGELOG.md` under `[Unreleased]`, then
move them to a dated version section for release. Keep version strings out of code.
