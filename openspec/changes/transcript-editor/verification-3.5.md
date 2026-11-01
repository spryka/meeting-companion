# 3.5 — audio failure UI/documentation (HIGH accepted)

Audit: Core/adapter already reject unavailable, missing, corrupt, nonregular/unreadable and escaping symlink paths without fallback, stop playback on native failed event and retain text. No duplicate player/controller implementation added. Changes are localized Published audio message + accessible status text, actual error harness and current user documentation. Parent 3.5 remains open pending HIGH.

UI distinguishes loading, explicit `playback.unavailable` («не подготовлено»), load/runtime failed («файл отсутствует, повреждён или недоступен»), and legacy/non-review audio unsupported. Ready/playing hide the message. Closed model preserves last message without accepting callbacks. No absolute paths/interpolated backend errors in audio status. Controls stay disabled on error; selected version, saved turn text/name overrides remain visible. No retry/rebuild/fallback added.

## Evidence and TDD qualification

New harness source and nil-message API skeleton preceded implementation. Initial attempted RED used an old synthetic clip deleted by its original harness; it failed on missing test input, **not semantic RED**. This was discovered after implementing the message. To verify the intended RED honestly, compiled the pre-edit window snapshot plus nil-message API in temp `RedWindow.swift` against valid synthetic input: semantic failure `missing: localized path-free audio message`, while earlier existing safety assertions pass. This is baseline comparison evidence, not an in-order production RED run; production wasn't reverted. Existing safety is preexisting GREEN regression coverage, not newly implemented behavior.

Final actual AppKit/AVPlayer error harness: **52 checks GREEN** across missing, corrupt bytes, explicit unavailable, and native runtime failure after deletion. Valid master/host/remote/other mix alternatives deliberately present. Exact actual selected asset checked before deletion and unchanged asset identity after failure (avoids macOS /var vs /private alias resolution after unlink). Saved overrides/selection preserved; player disabled; observer zero; late close callbacks inert; synthetic files byte-identical except intentional deletion. Native failed-to-end notification is injected at real AVPlayerItem boundary for determinism: unlink alone may continue cached playback and is not claimed to cause immediate OS failure. Unreadable permissions not forced under privileged test user; existing Core readable-file guard and symlink tests inspected, no new UAT claim.

- Full Swift **149 tests /15 suites GREEN**, no new SwiftPM tests; integration checks standalone.
- Existing actual player-window **27 GREEN**, history/window **15 GREEN**.
- Release, strict OpenSpec and diff check exit0.
- No Core/producer/contracts edits, no file regeneration/fallback, Python/network/install/commit/push/subagents/Gemini.

Docs now describe actual read-only history/window/version/player/follow and recovery, while section4 editing/export UI remains future. Root status no longer incorrectly says all section3 UI absent. Physical AX/VoiceOver/keyboard/wheel, human listening/AEC/hardware/performance remain 5.2/5.3b.

All203 baseline/manifest/status, allowlist, exact commands, full logs/patch/integrity in approved temp `section3-3.5`, `builder.md`. New report does not close 3.5 or section3 before HIGH.

## Independent HIGH acceptance

`section3-3.5/high-review.md`: принято без блокеров, 0/2 fix cycles. Независимо **52 error +27 player +15 window +21 дополнительных actual-model checks GREEN**. Проверены nonregular/symlink rejection при валидных альтернативных assets, explicit valid-version recovery, retained callbacks и native notification после close. P3 документации исправлен отдельно: реализованный version selector отделён от будущих editing interactions.

3.5 закрыт после HIGH в программном scope. TDD-order exception остаётся: post-hoc semantic RED на точном baseline, а не strict test-first; первоначальный missing-fixture failure не RED. Runtime failure — injected native notification, не доказательство OS failure от unlink. Path-free гарантия относится к audio status в окне, **не глобальна**: неизменённый outer open-error handler в RecorderAppDelegate может показывать localizedDescription. Human UAT остаётся 5.2/5.3b; финальные current-source результаты и ограничения — verification-section-3.md.
