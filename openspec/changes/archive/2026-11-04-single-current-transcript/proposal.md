# One current transcript

## Why

The owner's workflow is record → process → read/correct/copy/listen. User-visible recognition history, selection persistence and a second recording-format marker add states and defects without serving that workflow. Owner explicitly requests to revise and implement this simplification, preserve original audio separately, and critically remove unnecessary machinery. Owner explicitly retains manual text and speaker-name corrections.

## What Changes

- One current transcript per recording; remove the version picker, old-result navigation, async version-switch drafts/prompts and associated production APIs that exist only for that scenario.
- Retrying explicitly processes preserved original audio and replaces the current result shown to the user after successful publication. No automatic transfer of edits to unrelated new turn IDs. Never silently discard an unsaved draft.
- Compatibility comes from the existing result.json/schemaVersion and validated artifacts. Remove recordingFormatVersion creation, encoding and compatibility gates, without introducing a renamed parallel marker.
- New recordings retain original microphone/system WAVs under raw/, existing descriptive filenames, timeline/mute semantics and immutability. AEC/corrected audio/mix must remain distinguishable derivatives and may never replace originals.
- Existing compatible structured recordings remain usable; existing unsupported/missing result may expose saved TXT read-only and manual reprocess from supported source pairs. No automatic processing, migration or deletion.
- Existing old result/edits files are preserved. They are not a user-visible history. User explicitly allowed retaining files while removing access to previous results from the product. No storage-layout/schema rewrite solely to remove the picker; technical result identity for safe publication and edit binding may remain.
- Fix or eliminate both independently accepted beta5 defects through the final behavior: repeated-save format-marker corruption and async-switch draft loss. Other five closed service/caller fixes remain intact.

## Capabilities

### New Capabilities

- single-current-transcript: one current result, safe replacement, original separation, schema-based compatibility and manual reprocessing.

### Modified Capabilities

The current root openspec/specs has no main capability specs. The change supersedes the conflicting recognition-history requirements in existing transcript-editor/native runtime change documents. New ADR supersedes those parts of ADR-0001/0003 without rewriting accepted records. Atomic publication, separate edits, off-main services and worker isolation remain.

## Impact

App/Core/Application current-result resolution, editor lifecycle and retry callers; worker/publication only where needed to expose the actual successful new result consistently. Capture paths already use raw/; do not rename them or redesign capture. Tests/fixtures, current OpenSpec/ADR/docs and next signed beta. No DSP/model/download changes, new dependencies, actual user data/cache/preferences edits, installation, Git or archive. Existing earlier budgets/counterexamples remain recorded; this is an explicit owner-authorized scope revision, not a renamed automatic repair.


## Latest owner cutoff — ADR-0005 (2026-11-03)

Full functionality requires canonical folder basename == recording stem, independent of raw existence/age/producer/markers. Standard capture starts before raw exists; valid structured data without originals retains editor/playback. Retry separately requires exact contained raw host+remote WAVs, never automatic flat fallback. Nonstandard placement is list + available standalone contained saved TXT read-only, with no shared structured lookup, context/calendar mutation, durable history writes, capture or processing. Flat display metadata stays at its exact root path even if raw appears. Enforce guards before side effects in Application enqueue/start, every durable history writer, Platform Recorder/Transcription, and Worker recording mode. Explicit developer pair mode keeps its separate output-directory contract. Preserve all files and prior one-current/publication/draft/service safeguards; no migration. This supersedes earlier flat-retry clauses only; accepted ADR1–4 remain unchanged.
