# ADR-0005: Standard recording folder ownership

Status: accepted
Date: 2026-11-03
Supersedes: ADR-0004 automatic flat-source retry clause only

## Context

The owner explicitly narrows support after confirming dedicated recording folders
and raw/ shipped in 1.4.0 (2026-10-18). Shared flat folders cannot safely own one
current result. Policy approval is separate from implementation acceptance.

## Decision

Full functionality requires the canonical containing folder name to equal the
recording stem. This does not require raw/ at capture start. Supported structured
results retain editor/playback without originals; retry separately requires the
exact contained raw host/remote pair. No automatic flat-source fallback.

Nonstandard placement is list plus available contained standalone saved TXT,
read-only. Do not resolve shared structured results, process, capture, mutate
calendar/context or write metadata for it. Existing descriptive flat metadata may
be read from its exact root path even if raw/ later appears. Preserve all files;
no migration, moves, markers or new storage namespace.

## Consequences

Use the shared Core layout rule at actual capture/processing/history boundaries
before side effects. One-current selection, atomic publication, edits/CAS, worker
isolation and Application lifecycle remain. Explicit developer host/remote mode
keeps its separate output-directory contract. UAT and review remain separate.
