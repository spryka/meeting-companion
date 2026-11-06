# Section 3 — programmatic acceptance complete

Tasks 3.1–3.5 и их children закрыты по независимым Sol/HIGH reviews. Это реализация и программная приёмка просмотра/аудио, **не релиз, не полная UAT-приёмка приложения**. Sections 1/2 и согласованный 1.0 остаются закрытыми; section4 editing/export не реализован этим разделом и остаётся открытым.

## Actual scope and evidence

| Task | Реализовано и проверено | Независимое evidence |
|---|---|---|
| 3.1 | Индекс общей шкалы, overlap/pause/seek; все активные реплики в DISPLAY order | [verification-3.1.md](verification-3.1.md), независимая приёмка +103400 fuzz queries |
| 3.2 | History route, canonical one-window focus, pinned picker, throwing live history persistence, legacy/corrupt/unavailable TXT, close cleanup | [verification-3.2a.md](verification-3.2a.md), [verification-3.2b.md](verification-3.2b.md); 28 Core, 15+13 actual AppKit checks, actual NSApplication lifecycle release |
| 3.3 | Streaming AVPlayer selected-version mix only; actual play/pause/global seek, async/stale-event safety, retained overrides, highlights | [verification-3.3a.md](verification-3.3a.md), [verification-3.3b.md](verification-3.3b.md); 14 Core +12 adapter checks, repeated true-end/overlapping seek; 16+15+7 actual window/model checks |
| 3.4 | Default first-display follow, discrete scroll requests, manual/editing suspension and explicit return, pause/close observer cleanup | [verification-3.4.md](verification-3.4.md); 8 state +27 actual window +18 adversarial model checks |
| 3.5 | Missing/corrupt/unavailable/runtime failure retains selected text/overrides, disabled controls, accessible localized audio status, no fallback/rebuild | [verification-3.5.md](verification-3.5.md); 52 error +27 player +15 window +21 additional model checks |

Counts overlap between iterations and **are not summed as unique tests**. HIGH artifacts are in approved OpenCode temp folders `section3-3.2b/3.2b-high-review.md`, `section3-3.3a/3.3a-high-followup1.md`, `section3-3.3b/high-review.md`, `section3-3.4/high-review.md`, `section3-3.5/high-review.md`; per-step reports link commands and full logs.

## Fresh final current-tree verification

After documentation acceptance edits, offline current sources freshly compiled (no reused harness binary):

- Full Swift suite: **149 tests /15 suites GREEN**.
- Release `swift build -c release --disable-automatic-resolution --skip-update`: exit0.
- Actual AppKit/SwiftUI/Core/AVPlayer player/follow synthetic harness: **27 checks GREEN**.
- Actual audio-error harness with fresh synthetic clip produced by that player harness: **52 checks GREEN**.
- Actual history/window harness: **15 checks GREEN**.
- `openspec validate transcript-editor --strict`, `git diff --check`: exit0, repeated after this report.

Exact commands/script and every exit: approved temp `section3-3.5/section3-final-checks.sh`, `section3-final-commands.log`, `section3-final-exits.log`, `section3-final-*.log`. Swift tests use explicit TestingMacros plugin and `--disable-automatic-resolution --skip-update`. Synthetic media is short local PCM WAV via AVAudioFile, not user audio. Installed app not launched/quit; no install, commit, push, network or Python. Section5.1 remains open because the full prescribed integration/Python checks were not performed here.

Final docs-only snapshot: `section3-final-before/` includes all205 Git-listed tracked/untracked nonignored files, SHA-256 manifest, full status and tracked/staged binary patches. Allowlist: user docs, tasks 3.5 checkbox, verification-3.5.md and this new report; code and existing tests unchanged. `section3-final-integrity.log` / `section3-final.patch` capture final scope; staged bytes preserved. Parallel migration files were not altered.

## Explicit limits / workflow exceptions

- There is actual read-only browse/version/player/follow UI. No name assignment/text editing forms/unsaved-input UX/new saved-edits export UI from section4; beginEditing is only a future integration hook.
- Physical wheel/keyboard/scrollbar/text-selection delivery, visible scrollTo, dark/light and VoiceOver **not executed**; task5.2 stays open. Programmatic native phase/handler wiring is not a substitute.
- Human listening, hardware/AEC correspondence and quality UAT **not executed**; task5.2 stays open. Actual short synthetic clips prove readiness/head movement/pause/seek, not audible quality.
- Eight-hour offline/performance/memory UAT **not executed**; 5.3b stays open. Accepted thresholds5.3a stay closed; no performance guarantee inferred from streaming implementation.
- 3.5 TDD-order exception: semantic RED was post-hoc on exact pre-edit baseline after discovering a missing synthetic input; it is **not strict test-first**. Initial fixture failure is not RED. Existing safety was regression-tested, not reimplemented.
- Runtime failure evidence is injected real AVPlayerItem notification after unlink, **not proof that unlink immediately triggers native failure** (cached audio may continue).
- Path-free claim is for the audio status summaries, **not global sanitization**. Unchanged outer open-error handler may display localizedDescription including technical details.
- Security checks reject preexisting unsafe paths/symlinks; no protection against arbitrary concurrent filesystem TOCTOU writer is promised.

5.2/5.3b/5.4 and section4 remain open. No archive/release acceptance implied.
