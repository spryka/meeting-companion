# Core Audio Tap experiment

Isolated prototype; the application does not import or execute it.

System audio uses a private, unmuted Core Audio process tap and aggregate device.
Microphone audio uses AVCaptureSession. Both use host-clock timestamps and the
existing SourceAudioFile writer, which produces padded 16 kHz mono PCM16 WAVs.
The probe prefers the built-in MacBook microphone for this experiment.

Compile with assertions enabled from the repository root:

```sh
swiftc -swift-version 5 -parse-as-library experiments/core-audio/Probe.swift \
  Sources/MeetingCompanionCore/SourceAudioFiles.swift -o /tmp/meeting-tap-probe
```

For the observed runs it was launched inside a separate signed application bundle
`local.meeting-companion.audio-probe`, with NSMicrophoneUsageDescription and
NSAudioCaptureUsageDescription. It requires its own user-granted permissions.
Launching as a terminal executable may attribute permission requests differently.
The probe records for 60 seconds and logs to `/tmp/meeting-tap-probe.log`;
audio goes to a new `/tmp/meeting-tap-<UUID>` directory. It never plays audio.

The assertions require both sources to deliver buffers. Run with audio playback
active, including digital silence: a tap may deliver no buffers while the output
is inactive. No buffers during silence is not itself a recording failure.

## Observations, 2026-10-16

Global GPU utilization was sampled once per second from AGXAccelerator's
PerformanceStatistics, Device Utilization %. Other applications were running;
these are short observations, not isolated benchmarks or per-process GPU usage.

| Mode | Samples | Median global GPU |
| --- | ---: | ---: |
| Installed 1.2.0 recording, capsule visible | 12 | 92% |
| Installed 1.2.0 recording, application hidden | 12 | 90.5% |
| After installed recording stopped | 12 | 18.5% |
| Tap + AVCapture, first successful two-source run | 12 | 30.5% |
| Tap + AVCapture, active output playing digital silence | 20 | 10% |

The last probe run completed with 5,979 microphone buffers and 5,978 system
buffers. First timestamps were +52.856 ms and +37.906 ms from the common epoch.
Largest positive timestamp gap was below 0.001 ms in both sources.
Both finished WAVs contained 1,021,549 samples at 16 kHz, mono PCM16.
The microphone contained nonzero audio; the system track contained the expected
digital silence. A previous audible reference signal was captured in the system
track with the expected peak of 4,000 PCM16 units.

These checks establish a shared timestamp scale and continuity in a short run.
They do not establish acoustic latency, hour-long drift, Bluetooth microphone
behavior, device-switch recovery, or speech recognition quality.

## Production implementation

Version 1.3.0 adds a separate production backend in
`Sources/MeetingCompanionCore/AudioCapture.swift`; this prototype remains isolated.
The application copies audio into a bounded serial delivery queue, uses the selected
microphone, preserves synchronized source WAVs and exports an audio-only M4A mix.

Short application checks on 2026-10-16 (12 global GPU samples each):
ScreenCaptureKit without recording output: medians 98% and 88%; Core Audio Tap: 14%;
after Tap stopped: 16%. Other applications were running. These are not isolated
benchmarks. A 69-second Tap recording saved equal-length source WAVs, the M4A had
one audio track and no video, and automatic transcription completed. System audio
in that run was digital silence; speech quality was not evaluated.

## Original prototype checklist

- Move file writes and conversions off the HAL callback, with bounded buffering
  and an explicit error on overflow; the prototype writes synchronously.
- Respect the selected microphone, exclude the recorder's own process, and handle
  capture failure/device interruption with cleanup and preserved recordings.
- Keep the full-quality mixed M4A backup alongside the existing synchronized WAVs;
  this probe creates only WAVs and does not exercise mixing or transcription.
- Update audio permission diagnostics: screen-capture preflight does not prove
  Core Audio Tap permission. Do not reset existing permissions automatically.
- Check repeated start/stop and a long recording before replacing the backend.
