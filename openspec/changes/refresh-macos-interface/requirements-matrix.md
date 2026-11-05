# Матрица требований

W/R/M/P реализованы и прошли ограниченные source reviews; это не полная runtime-приёмка. Requirements/scenario ID сохранены. Проверки workspace, menu/capsule, settings и visual boundaries разделены в verification-документах; непроведённый physical UAT остаётся WAITING_UAT.

Итог beta24/build60, merge/install, exact selected checks и полный register каждого
обязательного scenario ID — [verification-release.md](verification-release.md).
Реализация/source release завершены; partial/not-run не означают отсутствие
продукта и не снимают обязательность оставшихся проверок. Practical design guide —
[DESIGN.md](../../../DESIGN.md).

| Требование | Спецификация | Все сценарии | Задача | Проверка |
|---|---|---|---|---|
| W01 Integrated recording workspace | [desktop-workspace](specs/desktop-workspace/spec.md) | W01.1, W01.2, W01.3, W01.4, W01.5 | 3.1 | UI harness и UAT |
| W02 Window width navigation | [desktop-workspace](specs/desktop-workspace/spec.md) | W02.1 | 3.2 | UI harness и UAT ширины |
| W03 Local library search | [desktop-workspace](specs/desktop-workspace/spec.md) | W03.1, W03.2 | 3.3 | TDD поиска и UAT |
| W04 Preserve transcript review contract | [desktop-workspace](specs/desktop-workspace/spec.md) | W04.1, W04.2, W04.3, W04.4, W04.5, W04.6, W04.7, W04.8, W04.9, W04.10 | 3.4, 3.9, 3.11 | Регрессия Core/UI и UAT |
| W05 Current result playback and follow | [desktop-workspace](specs/desktop-workspace/spec.md) | W05.1, W05.2 | 3.5 | Регрессия player/audio-error и UAT |
| W06 Export current saved result | [desktop-workspace](specs/desktop-workspace/spec.md) | W06.1, W06.2 | 3.6 | Регрессия export и UI |
| W07 Honest record states and actions | [desktop-workspace](specs/desktop-workspace/spec.md) | W07.1, W07.2, W07.3, W07.4, W07.5, W07.6, W07.7 | 3.7, 3.10 | TDD states/rename reload/error/job race/legacy и UAT |
| W08 Native accessibility and long offline review | [desktop-workspace](specs/desktop-workspace/spec.md) | W08.1, W08.2 | 3.8 | Synthetic long transcript/transport; темы/accessibility UAT; long physical WAITING_UAT |
| R01 Successful start before hiding workspace | [recording-overlay](specs/recording-overlay/spec.md) | R01.1, R01.2, R01.3 | 4.1 | TDD переходов и capture UAT |
| R02 Independent workspace visibility | [recording-overlay](specs/recording-overlay/spec.md) | R02.1 | 4.2 | TDD lifecycle, AppKit harness и UAT |
| R03 Rounded capsule and long duration | [recording-overlay](specs/recording-overlay/spec.md) | R03.1, R03.2, R03.3 | 4.3 | TDD границ времени и UAT геометрии |
| R04 Explicit microphone mute | [recording-overlay](specs/recording-overlay/spec.md) | R04.1, R04.2 | 4.4 | Существующая mute regression и физический audio UAT |
| R05 Preserve short cancellation and overtime | [recording-overlay](specs/recording-overlay/spec.md) | R05.1, R05.2, R05.3 | 4.5 | Регрессия short/overtime и UAT |
| R06 Processing and recovery lifecycle | [recording-overlay](specs/recording-overlay/spec.md) | R06.1, R06.2, R06.3, R06.4, R06.5, R06.6 | 4.6 | Регрессия queue/progress/retry и UAT |
| R07 Position focus and Spaces | [recording-overlay](specs/recording-overlay/spec.md) | R07.1, R07.2, R07.3 | 4.7 | Geometry tests и UAT мониторов/Spaces |
| R08 Protected quit and install | [recording-overlay](specs/recording-overlay/spec.md) | R08.1, R08.2, R08.3 | 4.8 | Update policy regression и UAT |
| M01 Consistent status item click | [macos-status-menu](specs/macos-status-menu/spec.md) | M01.1 | 5.1 | AppKit harness и UAT |
| M02 State derived commands | [macos-status-menu](specs/macos-status-menu/spec.md) | M02.1, M02.2, M02.3, M02.4 | 5.2 | TDD state matrix/concurrency/stale dispatch через actual callers и UAT |
| M03 Status icon and shared state | [macos-status-menu](specs/macos-status-menu/spec.md) | M03.1, M03.2 | 5.3 | TDD shared state/capsule identity и UAT тем |
| M04 Stable utility commands | [macos-status-menu](specs/macos-status-menu/spec.md) | M04.1, M04.2, M04.3, M04.4 | 5.4 | AppKit harness selectors/keyboard/programmatic/update/quit guards и UAT |
| P01 Five settings sections | [preferences-navigation](specs/preferences-navigation/spec.md) | P01.1, P01.2, P01.3, P01.4, P01.5, P01.6, P01.7 | 2.1 | UI harness и UAT |
| P02 General settings continuity | [preferences-navigation](specs/preferences-navigation/spec.md) | P02.1, P02.2 | 2.2 | TDD binding и нативный UAT |
| P03 Recording settings continuity | [preferences-navigation](specs/preferences-navigation/spec.md) | P03.1, P03.2 | 2.3 | TDD binding и audio/folder UAT |
| P04 Transcription settings continuity | [preferences-navigation](specs/preferences-navigation/spec.md) | P04.1, P04.2 | 2.4 | Preparation regression и UAT |
| P05 Safe owned cache reset | [preferences-navigation](specs/preferences-navigation/spec.md) | P05.1, P05.2, P05.3, P05.4, P05.5 | 2.5 | TDD reset guards и UAT |
| P06 Calendar settings continuity | [preferences-navigation](specs/preferences-navigation/spec.md) | P06.1 | 2.6 | Calendar regression и EventKit UAT |
| P07 Diagnostics settings continuity | [preferences-navigation](specs/preferences-navigation/spec.md) | P07.1, P07.2 | 2.7 | Diagnostics regression и физический UAT |
| P08 Operation specific locks | [preferences-navigation](specs/preferences-navigation/spec.md) | P08.1, P08.2, P08.3, P08.4, P08.5 | 2.8 | TDD таблицы разрешений действий |

## Контроль сохранения функций

| Возможность | Покрытие |
|---|---|
| ADR0001 immutable results/edits + ADR0004 current-only + ADR0005 layout | W04, W06, задача 1.3 |
| Legacy read-only, ошибки чтения | W04, W07 |
| Микс current result, AEC provenance, missing audio | W05 и сохранение контракта transcript-editor |
| Перекрытия и manual follow pause | W05 |
| Одна реплика / тот же source/voice отсюда до конца, preview | W04.5, W04.6 |
| Редактирование текста, поиск и экспорт правок | W04.1, W04.4, W06 |
| Календарные подсказки и ручной ввод без календаря | W04.7, W04.8 |
| Allowlist экспорт и дословный пользовательский текст | W06 |
| Приглашённые не равны установленным именам | W04, W07, P06 |
| Короткая отмена и overtime 15 минут | R05 |
| WAV/CAF и delayed mute | R04, R06 |
| Очередь, retry и одновременные состояния | W07, R06, M02 |
| Мониторы, Spaces и фокус | R07 |
| Выход, обновления и запрет установки поверх работы | R08, M04 |
| Сохранённые настройки и locks | P01-P08 |
| Только app-owned cache | P05 |
| Разрешения и ограниченная проверка звука | P07 |
| Восемь часов offline и длинный таймер | W08, R03; synthetic сейчас, long physical WAITING_UAT |

## Границы подтверждения

Подтверждены визуальный референс, обязательный status menu и одинаковое меню по обоим кликам. ADR0006/0007 действуют. Владелец принял beta23 divider для сообщённого использования и разрешил release finalization; source review не подтверждает весь UI/audio/UAT.

## Дополнительная closure проверка

| Сохранённая гарантия | Scenarios / regression boundary |
|---|---|
| Modal draft + stale completion + admission/teardown без cross-window prompt | W04.1/W04.2/W04.9/W07.2, App composition и shared ProcessingService |
| Source/voice remaining, manual overwrite, examples, no-op/CAS | W04.3–W04.6, Core assignment preview/apply + actual modal caller |
| Saved-only suggestions без permission/network/identity inference | W04.7/W04.8, doc.context.attendees + UI |
| Display rename atomic reload/error/ongoing-job/flat | W07.3–W07.6, existing history repository + lifecycle/current load |
| Native model-check progress вне Details | P04.1 + main model-check-progress, shared check/preparation snapshots |
| Нет saved undo/history/new Cmd-Z, есть field undo/Cancel | W04/W04.1/W04.6/W04.10, actual toolbar/keyboard/edit field |

Не использовать прежние beta8 results как доказательство нового GUI. Independent review читает actual production caller closure на after hashes; подробный код не заменяется этой таблицей.

## Интеграция соседних контрактов

| Target / изменённые clauses | Refresh authority / сохранённая граница |
|---|---|
| transcript-review: History entry point, Turn text editing, Explicit speaker assignment, retry reopen | W01/W04; workspace/modal, remaining original source/voice, preview/confirm/no-op, field undo/Cancel; без saved undo |
| transcript-document: Recognition version isolation, Safe format handling | W04/W07; current-only, immutable disk versions, admission/teardown/CAS, ADR0005 flat TXT read-only |
| native-transcription-runtime: Enforced module dependencies, Reuse editor and recording boundaries, Compatible artifacts and immutable versions, Retry with an open editor | W01/W04; unchanged result/edits formats и Application lifecycle, без separate-window prompt/saved undo GUI |

Это согласование контрактов, не runtime closure. Accepted ADR и исторические результаты не переписываются.

## Текущие production boundaries и оставшиеся проверки

| Scope | Production / test boundary | Что ещё не подтверждено |
|---|---|---|
| W01/W02 | Delegate.showWindow → showWorkspace/requestWorkspaceOpen/loadWorkspace; RecordingHistoryView → AppWindowState.updateHeader; existing workspace manager | Полный native reopen/focus/resize/drag matrix |
| W03 | RecordingSearch saved current+edits, generation/cancellation; flat contained TXT | Полный keyboard/поиск UI flow |
| W04 | TranscriptEditsRepository CAS/atomic saves; remaining assignment preview/apply; modal admission/result identity/late-open guards | Native input/Cancel/field undo, VoiceOver, focus |
| W05 | PlaybackController/AVPlayer transport, interval/follow, bounded waveform | Реальный playback/качество/многочасовая память |
| W06 | Saved-only copy/export; formatter, protected writer, bound save-panel callback | Системный panel/clipboard и pointer flow |
| W07 | Existing history repository/displayTitle/capabilities; exact raw pair/current teardown | Физический Finder/retry/error flow |
| W08 | Semantic controls, native workspace; synthetic long document/transport | Контраст, macOS15 fallback, reduced motion/transparency, keyboard/VoiceOver, physical long run |
| R01–R08 | RecordingSessionService/ProcessingService → shared model → independent RecordingCapsuleController; session-bound commands/terminal ownership | Capture/mute/source-loss/short cancel/overtime; monitors/Spaces/fullscreen/drag; busy quit/update |
| M01–M04 | StatusMenu.build → UUID/intents selectors → shared service admission; command state matrix, explicit library/settings/quit/update | Реальные оба клика, shortcut/focus/a11y и concurrency |
| P01–P08 | model-owned Settings modal; actual form callbacks/visibility, pending handoff/reset commit, updater policy and bindings | Реальные overlays/background blocking/focus, devices/EventKit/SMAppService/model reset/update |

Релевантные existing tests находятся в Core/Application suites и App production
composition/presentation suites. Model-dependent App helpers eagerly создают
EKEventStore: они не считаются безопасными лишь из-за пустого selection и не
повторяются в finalization. Три pure App checks и pure pipeline document assembly
не заменяют всю прежнюю suite. Точные текущие результаты — в verification.

Сохранённые historical failures: full suite с nested SwiftPM sandbox/AAC error,
исходный module-boundary sandbox failure, исходный window dark-appearance assertion,
неполные native summaries и недоступные render/interaction checks. Fresh selected
GREEN не меняет их статус и не доказывает18-row visual equality.
