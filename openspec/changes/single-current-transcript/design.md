# Design constraints and minimal path

## Decisions authorized by owner

User-visible workflow is one current transcript, no recognition history/chooser. Keep manual text/name correction (explicit reply), viewing, copy/export and listening. Existing source capture already writes raw/<stem>.host_record.wav and raw/<stem>.remote_record.wav; preserve these names and PCM/timeline/mute behavior. Existing result.json has schemaVersion1; do not introduce schema2 or another metadata format gate merely for a UI simplification.

## Current-result storage

Reuse validated JSONv1 publication, result identities and per-result edit binding where needed. Older on-disk files may remain to meet the no-deletion instruction, but are not exposed as product history. Remove selection APIs/state/prompts which have no remaining caller instead of hiding the Picker alone. A small current-result resolver is allowed by adapting existing code; no new universal store, history database, fallback parser, duplicate pointer formats, result manifests or migration subsystem.

Builder must trace and choose one minimal authoritative current-result path through native publication → Application → history → actual GUI/CLI open/reopen. Existing selectedResultID is legacy saved state, not a continuing user choice; it must not keep a superseded result active. Avoid speculative rewrite of the stable raw/transcripts/<id> contract or overwriting a result under a reused ID that would attach old edits to new recognition. If an internal current pointer is needed, reuse a single existing ownership field and retain transaction semantics; do not create parallel authorities.

The new current result and text must be consistent at the observable boundary. A failed metadata/text save must not announce successful new publication or render a half-result. Preserve accepted terminal memory-state/warning behavior without resurrecting a UI queue, synchronous MainActor I/O or suppressing errors.

## Open editor and retry

There is no version-switch action. Before replacing a current result, actual GUI callers resolve unsaved edits using the existing save/discard/cancel pattern. During the transition, stale sessions cannot overwrite the new result or silently lose a draft. New result IDs remain edit identity if the storage uses them; old saved edits stay with their old data and are not auto-applied. Keep useful existing text/name edit repositories, containment/CAS/atomic writes and close-window safeguards. Remove the obsolete version navigation path and tests, replace them with current-result replacement regressions; do not weaken unrelated transactional assertions.

## Critical simplification inventory

Remove: Picker/version list and switch/reselect flows, version-navigation-only draft authorization/prompts/tasks, user-selection persistence callback, recordingFormatVersion field/gates/header parser if no other caller, dead tests/helpers/UI solely for those features, misleading version language. Simplify duplicated compatibility checks by reusing actual document schema validation and the existing deterministic source contract.

Keep: one shared Application queue/session/history, cooperative cancellation and bounded subprocess ownership, preparation progress and exclusivity, model cache integrity, atomic publication/staging, immutable originals, unknown metadata preservation, capture warnings, structured result timestamps/speakers, user text/name edits, current playback/export, contained read-only TXT and manual retry for supported old sources.

Do not remove calendar, diagnostics, audio-device settings, mute or model options just because unused in a small code sample. Record any further candidate for removal with concrete user/caller evidence; do not silently widen into a whole-app redesign. No additional model/package alternatives or quality/performance experiments.

## ADR and verification

Create a short new ADR superseding only the history/selection clauses of accepted ADR-0001 and corresponding ADR-0003 wording; leave accepted files intact. Document owner approval from the explicit current request, not inferred production acceptance. Reconcile current OpenSpec scenarios before behavior edits and run strict validation. This proposal is for a small preimplementation read-only review; actual implementation and final review remain separate.

Regression evidence must cover disk reload after lifecycle saves (not cache-only), old marker/unknown metadata preserved without gate, supported old JSON, raw-only retry, denied flat processing and unsupported current result, repeated publication/current GUI selection with old selectedResultID, cancellation/failure preserve originals and state, draft boundary during delayed replacement, and no version controls/routes in actual GUI. Foundation/synthetic fixtures first. No new inference/downloads, audio>30s, user data/cache/preferences/install/Git/archive. Reuse previous accepted model/audio/AEC evidence at its original scope.

## Coordinator decision: current authority and commit (supersedes open choice above)

Use the existing atomic result-directory publication as the ONE authority; no new current pointer/manifest or metadata schema. For contained non-staging result directories, choose the most recently created directory by filesystem creation date, with directory name as a deterministic tie-breaker, BEFORE reading/validating its result.json. Do not use modification dates, selectedResultID or a list filtered by supported schemas. Existing imported directories use their actual stored creation date; tied copies use the same documented name tie-breaker. Thus A + newer unsupported/corrupt B + selectedResultID=A opens B as unavailable/read-only, never A. Missing result.json in an otherwise published candidate is also unavailable, not a reason to select A. Retain containment checks and exclude staging/dot/temp names.

Stage all mandatory result artifacts AND a plain-text rendering inside the result directory before the existing atomic no-replace rename. That rename is the commit. Before rename, any failure/cancellation keeps A current and preserves source/data; staging is excluded from discovery. After rename, B is durably current even if later acknowledgement/status persistence/cancellation fails. Consumers reconcile with committed disk state; do not advertise a rolled-back attempt or overwrite terminal state from stale metadata. Do not create a second current metadata write.

The existing root <stem>.sources.transcript.txt becomes a backward-compatible derived export cache, not an authoritative publication artifact. Refresh it after commit atomically; if refresh fails, return/show a persistence/export warning, retain committed B and never report the whole result unpublished. New App/CLI current-text/open paths read the text in B (or render B), never stale root TXT for a supported current result. Existing standalone TXT remains the explicitly read-only compatibility path when structured current data cannot be displayed; label it saved text, not B/new success. Do not modify original audio or remove old saved TXT/results. This deliberately avoids pretending a directory rename + unrelated root TXT write is one atomic transaction. Tests inject failure before rename, after rename/root export, and status persistence; reopen must match this exact boundary.

Before enqueue from actual GUI retry, resolve drafts via save/discard/cancel, close old session and gate editable reopening for this recording until terminal processing state. Cancel at the prompt means no enqueue. Reopen after terminal resolves the current published directory afresh. Keep stale-session/CAS protection and ordinary close-window draft protection; delete version-switch machinery.


## Latest owner cutoff — ADR-0005 (2026-11-03)

Full functionality requires canonical folder basename == recording stem, independent of raw existence/age/producer/markers. Standard capture starts before raw exists; valid structured data without originals retains editor/playback. Retry separately requires exact contained raw host+remote WAVs, never automatic flat fallback. Nonstandard placement is list + available standalone contained saved TXT read-only, with no shared structured lookup, context/calendar mutation, durable history writes, capture or processing. Flat display metadata stays at its exact root path even if raw appears. Enforce guards before side effects in Application enqueue/start, every durable history writer, Platform Recorder/Transcription, and Worker recording mode. Explicit developer pair mode keeps its separate output-directory contract. Preserve all files and prior one-current/publication/draft/service safeguards; no migration. This supersedes earlier flat-retry clauses only; accepted ADR1–4 remain unchanged.
