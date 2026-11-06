# Beta.30: final owner acceptance and scope closure

Date: 2026-11-06. The owner accepted the delivered application and explicitly
declined all remaining checks and investigations discussed for the five changes:

> все что ты перечислил мне не нужно. все что нужно проверил и оно супер

This decision closes the agreed delivery. It supersedes earlier WAITING_UAT,
pending-archive and proposed-follow-up dispositions for the residual scope below.
It does not assert that unexecuted tests passed or that cancelled optimizations
were implemented. No follow-up change or backlog item is requested.

## Accepted delivery

The owner uses the application and accepts its recording, native Swift/MLX
processing, transcript viewing/editing, chronological turns, playback, interface
and keyboard behavior. Public release
[2.0.0-beta.30, build 66](https://github.com/spryka/meeting-companion/releases/tag/v2.0.0-beta.30)
contains the accepted production code. The latest automated evidence remains
475 tests, release/package checks and independent source/release reviews PASS.
This documentation closure does not change or rebuild the application.

The owner plans to use the beta in real scenarios and consider a stable release
later if no issues appear. No stable release is authorized by this closure.
The ordinary beta trial does not reinstate the withdrawn checklist below.

## Withdrawn residual scope

| Archived change | Residual scope withdrawn by the owner |
|---|---|
| [workspace-keyboard-navigation](../openspec/changes/archive/2026-11-06-workspace-keyboard-navigation/tasks.md) | Remaining physical/IME/layout/VoiceOver matrix and further investigation or conditional repair of the old first-search-result report |
| [chronological-transcript-turns](../openspec/changes/archive/2026-11-06-chronological-transcript-turns/tasks.md) | Further diagnosis of the original private audio examples and the remaining listening/editing UAT |
| [transcript-editor](../openspec/changes/archive/2026-11-06-transcript-editor/tasks.md) | Remaining historical integration checks, extended accessibility/audio checks and eight-hour thresholds; previous waivers remain historical evidence |
| [swift-mlx-pipeline](../openspec/changes/archive/2026-11-06-swift-mlx-pipeline/tasks.md) | Python/Swift parity and precision studies, comparative time/memory series, pending bounded-memory/public-API/chunking optimization plans, and remaining extended hardware/preparation/offline UAT |
| [refresh-macos-interface](../openspec/changes/archive/2026-11-06-refresh-macos-interface/tasks.md) | Remaining compound verification portions, geometry/accessibility/devices/Spaces matrix and eight-hour performance thresholds |

Historical unchecked boxes remain unchecked and are explicitly withdrawn rather
than reported as completed. Old failure logs and the distinction between source,
synthetic tests and physical observations remain unchanged in the archive.

## Main specification sync

Nine accepted capabilities are retained in `openspec/specs/`: transcript document
and review, native transcription runtime, workspace, status menu, preferences,
recording overlay, chronological transcript and workspace keyboard navigation.
The existing single-current, Python-free and model-check-progress specifications
are preserved.

The research-only `transcription-parity-evaluation` proposal is archived without
becoming a main specification. Pending VAD/ASR memory optimization, Nemotron
chunking and timing-API migration requirements are likewise retained only as
withdrawn historical scope. Development-only restrictions on installing or
publishing a test bundle are superseded by the owner's explicit release request.
Eight-hour benchmarks are removed from the accepted review contract; ordinary
offline review and native input/control behavior are preserved.

No recordings, transcripts, model caches, application settings, signatures or
released assets are changed by this closure. Future changes require a new scope;
these cancelled items do not carry an automatic obligation to resume them.
