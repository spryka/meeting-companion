# 3.4 — follow mode + UI (HIGH accepted, programmatic scope)

Scope: новый Core value state и 8 unit tests; native SwiftUI integration в TranscriptReviewWindow.swift; расширенный actual player-window harness. Parent 3.4 остаётся открытым до HIGH review. Producer/contracts/adapter/controller не менялись.

## Defined behavior

- Default following. Пока playing, scroll request указывает первую активную реплику в DISPLAY order (все overlaps по-прежнему подсвечены).
- Gap не вызывает jump; paused updates/seek меняют highlight, но не scroll. Следующая playing реплика создаёт request. Повторные ticks внутри той же реплики не создают новых requests.
- Manual user scroll и beginEditing приостанавливают follow до явного «Вернуться к воспроизведению». Play/pause/seek и version change не снимают пользовательскую паузу.
- Explicit return немедленно запрашивает текущую первую активную реплику, даже paused; в gap ждёт следующей playing active. Version change сбрасывает старый target; close закрывает state и отвергает updates/return.
- BeginEditing — только hook для будущего section4, editing UI не добавлен.

SwiftUI ScrollViewReader реагирует на Published monotonic request counter; scrollTo без animation. macOS15 native onScrollPhaseChange передаёт tracking/interacting/decelerating как user scroll; idle/animating не приостанавливают follow. Глобальные event monitors/bridge/timers не добавлены. Нативный handler общий для wheel/scrollbar/keyboard фазы, но физическая доставка этих жестов не проверялась. Actual phase API и handlers скомпилированы/вызваны в реальном NSWindow; физические жесты, VoiceOver и визуальное расположение остаются 5.2.

Observer lifecycle оставлен в принятом AVPlayer adapter: только actual playing, pause/close/version replacement снимают observer; UI не добавляет periodic observer. Закрытие model закрывает follow; stale playback guard не менялся.

## TDD / results

До реализации state API skeleton успешно скомпилирован; 8 tests упали семантически, `red.log` exit1 (не import failure). После реализации:
- **149 tests / 15 suites GREEN** (141 existing +8 new).
- **27 actual AppKit/AVPlayer checks GREEN** (16 existing +11 follow/lifecycle): overlap first-display, paused seek no jump, programmatic idle/animating игнорируются, manual suspension через pause/seek/play, explicit return, editing hook, version isolation, actual zero paused/closed observer и actual playing observer, close state.
- **15 existing window/history checks GREEN**.
- Release, strict OpenSpec, diff check exit0.

Нет production fix cycles. Full commands/logs, pre-edit all200 baseline/manifest/status, allowlist и incremental patch: approved temp `section3-3.4`, `builder.md`, `3.4.patch`, `integrity.log`. 3.3 HIGH acceptance finalized before snapshot.

Ограничения: actual user wheel/keyboard/scrollbar phase delivery и видимое scrollTo не являются пройденным human UAT. Только state/handler-level semantic assertions в actual window harness. Нет editing readiness, human listening/AEC/hardware/performance/theme/VoiceOver claims; нет Python/network/install/commit/push/subagents/Gemini. 3.4 checkbox остаётся открытым для независимого review.

## HIGH acceptance

Независимый review принят, 0/2 fix cycles: 8 follow tests +27 actual AppKit/AVPlayer +18 adversarial actual-model checks GREEN (`section3-3.4/high-review.md`, `high-commands.md`). Подтверждены repeated return, одинаковые ID разных версий, gaps, pending seek/late callbacks/closed handlers. Actual request→ScrollViewReader и native phase/return wiring проверены. Checkbox 3.4 закрыт только для программного state/handler scope; physical wheel/key/scrollbar/text-selection, видимое scrollTo и VoiceOver остаются 5.2. Section4 editor не заявлен.
