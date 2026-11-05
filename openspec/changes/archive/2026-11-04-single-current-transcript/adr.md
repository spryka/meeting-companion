# ADR Review Manifest

- Status: completed
- Review date: 2026-11-03

Reviewed accepted ADR-0001/0002/0003, unchanged. New ADR-0004 supersedes only
user-visible history/selection clauses of ADR-0001/0003, with explicit maintainer
approval in the one-current-transcript request and PLAN_PASS. Immutable results,
separate edits/CAS, Application ownership and isolated worker remain. Acceptance
of this decision is not shipped-behavior or UAT acceptance.


## Latest owner cutoff — ADR-0005 (2026-11-03)

Full functionality requires canonical folder basename == recording stem, independent of raw existence/age/producer/markers. Standard capture starts before raw exists; valid structured data without originals retains editor/playback. Retry separately requires exact contained raw host+remote WAVs, never automatic flat fallback. Nonstandard placement is list + available standalone contained saved TXT read-only, with no shared structured lookup, context/calendar mutation, durable history writes, capture or processing. Flat display metadata stays at its exact root path even if raw appears. Enforce guards before side effects in Application enqueue/start, every durable history writer, Platform Recorder/Transcription, and Worker recording mode. Explicit developer pair mode keeps its separate output-directory contract. Preserve all files and prior one-current/publication/draft/service safeguards; no migration. This supersedes earlier flat-retry clauses only; accepted ADR1–4 remain unchanged.
