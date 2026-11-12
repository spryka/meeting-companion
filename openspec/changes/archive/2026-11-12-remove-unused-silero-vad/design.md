# Design

## Context

Baseline: released2.0.0 source. At that baseline, runtime already used Nemotron intervals and did not prepare detector weights, but the build still included two unused detector implementations and progress displayed a separate station.

## Goals / Non-Goals

Remove both unused detector implementations and their build dependencies, configuration, adapters and obsolete tests. Keep recognition results, window masks, source timeline, checksum validation, cancellation and data preservation. No runtime migration, new model, network service or automatic cache deletion.

## Decisions

- Delete obsolete code instead of retaining a disabled path. In the vendored package remove the unused detector API branches and files; retain model code needed by the existing package. Keep adaptations reproducible in vendor patches/provenance and retain applicable licenses.
- Compute speech masks during completion of each Nemotron source, before its terminal event. Preserve failure/empty-interval diagnostics and admission of all windows where required. GigaAM and Parakeet receive the same masks and original samples as before.
- Remove the obsolete progress event/station throughout the bundled worker and application, with no compatibility shim. Progress is transient; the app uses its bundled worker, not a separately versioned producer. Result JSON/audio/edits contracts are unchanged.
- Route: audio → optional echo → diarization (including masks) → recognition → optional correction → saving. Both sources must complete before a source-aware station completes; warnings remain visible in capsule/details.
- Update current docs/specs and third-party descriptions. Historical changelog/archive records remain identifiable as historical; accepted ADRs are unchanged.
- Validate local beta2.0.1-beta.1/build81 through existing scripts and signing identity, then ship2.0.1/build82 after owner clean-cache preparation and transcription acceptance. Subsequent fixes affect only test synchronization.

## Risks / Trade-offs

- Hidden transitive detector references → inspect structured SwiftPM graph and actual release build closure, not only root manifest.
- Loss of diagnostics or source completion when folding the station → test source-aware warnings, empty/failure paths, four option combinations and native capsule/details rendering.
- Vendor patch drift → regenerate the relevant patch and verify recorded provenance/graph checks.

## Migration Plan

No migration or cache cleanup. Existing unused files on the user's disk remain until their explicit cache-reset action. Use an isolated empty model root for automated missing-model checks. The owner used the existing reset/download UI and accepted clean-cache preparation and transcription. Do not replace or quit the running app without checking activity.

## Open Questions

None. Implementation, independent review and the requested owner clean-cache preparation/transcription checks are complete.
