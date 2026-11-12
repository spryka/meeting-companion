# Remove the unused speech detector

## Why

Speech windows already come from Nemotron. Unused detector code and dependencies remain in the build, and a separate progress station makes this inexpensive calculation look like another model pass.

## What Changes

- Remove the local detector target, adapter, model manifest, vendor patch and obsolete tests.
- Remove the transitive detector implementation and unused detector entry points from the vendored audio package, keeping the used Parakeet implementation and dependency provenance intact.
- Remove the separate speech-search station from worker events, decoder, application snapshot and UI. Fold speech-window selection into Nemotron and preserve its diagnostics.
- Update active documentation, specifications and dependency notices. Preserve historical release evidence as history rather than describing it as current behavior.
- Validate a signed local2.0.1-beta.1/build81 through clean-cache owner UAT, then release2.0.1/build82.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `native-transcription-runtime`: no unused detector code/models in the executable dependency closure; speech-window selection remains derived from Nemotron.
- `processing-progress`: four mandatory stations and up to two optional stations, with no separate speech-search stage.

## Impact

Swift package graph, vendored audio adaptations and licensing metadata, model preparation descriptions, worker progress events, Core/Application progress types, UI fixtures/tests, current documentation and beta packaging. The bundled producer and consumer change together; old saved transcripts and audio are unchanged.
