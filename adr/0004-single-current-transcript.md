# ADR-0004: One current transcript

Status: accepted
Date: 2026-11-03
Supersedes: ADR-0001 and ADR-0003 user-visible history/selection clauses only

## Context

The maintainer explicitly requests one current transcript, manual text/name
corrections retained, originals separate, and removal of recognition history and
recording-format gates. PLAN_PASS authorizes this scoped implementation.

## Decision

Expose one current result: newest contained non-staging result directory by
filesystem creation date, then descending directory name on a tie, selected before
schema validation. Ignore legacy selectedResultID/recordingFormatVersion. Preserve
those unknown metadata bytes and all historical files without migration/deletion.
Compatibility uses existing JSON v1 and validated artifacts, independently of producer.

Stage mandatory JSON/audio/plain text, then atomic no-replace directory rename:
this is the sole commit. Root TXT is an atomically refreshed derived export cache;
post-commit failures warn and retain the new current result. No second current pointer.

Keep immutable per-result storage, separate manual edits and CAS/result identity;
never transfer old edits to new turn IDs. Before explicit GUI retry, resolve drafts
with save/discard/cancel, close the old editor and block reopening through terminal
processing teardown. Retain normal close protection and read-only saved-text access
with manual retry from existing exact contained raw/flat original source pairs.

## Consequences

No user-visible recognition history or selection transaction remains. Unsupported
newest results never silently fall back to older supported results. Old artifacts
remain on disk. Application/Platform/Pipeline boundaries, source timeline/mute,
worker isolation and cancellation remain unchanged. This accepted policy does not
claim implementation acceptance, physical UAT or permission to install.
