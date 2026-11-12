# Implementation and validation

## 1. Remove the unused detector

- [x] 1.1 Remove the local and transitive obsolete detector implementations, model declaration, adapter, tests and build dependencies; retain required model functionality and licensed provenance.
- [x] 1.2 Update the reproducible vendor patch, file inventory and graph checks.

## 2. Keep Nemotron window selection and simplify progress

- [x] 2.1 Calculate the same source-local window mask before each Nemotron terminal event; preserve samples, timeline, missing/failed/empty fallback, cancellation and warnings.
- [x] 2.2 Remove the separate speech-search event/station from worker, decoder, application route and UI fixtures; verify4 mandatory stages and6 with both optional stages.

## 3. Verify and review

- [x] 3.1 Confirm red/green route regressions, source diagnostics, real absent/damaged-model events and native light/dark routes for all AEC/Parakeet combinations.
- [x] 3.2 Fix test-only start-readiness and Process-termination synchronization with deterministic reproductions, bounded cleanup and preserved original signal/timeout assertions.
- [x] 3.3 Complete ordinary parallel swift test:594 Swift Testing +14 XCTest; module boundaries, recording finder, release build and strict OpenSpec validation.
- [x] 3.4 Independently review implementation/vendor/progress and test repairs; no unresolved findings.

## 4. Documentation and owner acceptance

- [x] 4.1 Update current pipeline documentation, worker help and dependency notices.
- [x] 4.2 Verify signed beta bundle/DMG and empty-cache model checks without downloading obsolete assets.
- [x] 4.3 Owner clears cache, downloads required models from scratch and successfully transcribes audio with no extra models.
- [x] 4.4 Validate the completed change with openspec validate remove-unused-silero-vad --strict before archive.

Owner acceptance covers clean-cache preparation and actual transcription. Physical VoiceOver and additional display/fullscreen matrices were not performed. Internal diagnostic transcripts, machine paths and agent journals are not part of the public change.
