# Контекст и карта границ

Изменение объединяет библиотеку, текущий текст и player в одном workspace,
оставляет независимую recording capsule и пять разделов Settings. Продуктовые
решения: current-only, text/name edits, remaining original source/voice scope,
live preview с подтверждением ручных замен, saved-calendar suggestions и manual
input, без GUI saved undo/history.

Референс — [reference/index.html](reference/index.html), provenance импорта —
[handoff-source.md](handoff-source.md). HTML не является приложением: fake devices,
permissions, waveform, timers, storage и Python-reset text не переносятся.
Настоящие системные controls/drag/fullscreen имеют приоритет над координатами
traffic lights в HTML. Settings — modal по ADR0007, без отдельного окна.

## Production ownership

Пути относительно Sources/; точные версии строк определяются исходниками.

| Граница | Текущие владельцы и callers |
|---|---|
| Composition/open | App/RecorderAppDelegate создаёт shared services; showWindow → showWorkspace/requestWorkspaceOpen/loadWorkspace; status/Dock/capsule/list используют существующий workspace |
| Header/content | App/RecordingHistoryView задаёт brand/actions/width/sidebar/list state; App/RecordingWindowState.attach/updateHeader переиспользует native accessories и narrow-detail background |
| Review/current | App/TranscriptReviewWindowManager → Core/TranscriptWindowCoordinator/TranscriptReviewSession/TranscriptEditsRepository; одна result-bound session |
| Text/name | Modal → Core/TranscriptSpeakerAssignment preview/apply и repository CAS; anchor/source/voice/target-name/snapshot связывают пакет |
| Rename | App/RecordingHistory → Application/RecordingHistoryRepository; optional displayTitle, atomic latest-entry update и исключение capture/admitting/queued/working |
| Search/export | App/RecordingSearch читает saved current/edits вне MainActor; existing Core formatter/writer и generation-bound callbacks |
| Recording/capsule | Application session/processing snapshots → App model → RecordingCapsuleController NSPanel; window visibility не завершает работу |
| Settings/menu | App/RecorderAppDelegate.showSettings → model-owned Settings; StatusMenu selectors и сохранённые callbacks повторяют admission/session identity |
| Reset | Settings → AppMain.performCacheReset; pending handoff ownership и свежие service reads проверяются после confirmation непосредственно перед синхронным commit |

## Сохраняемые гарантии

Original source timeline/mic-only mute, capture/export warnings и CAF при warning;
isolated worker/offline; atomic current publication; edits CAS/flock/result identity;
отсутствие автоматического carryover; exact raw retry; canonical layout/flat cutoff;
unknown metadata preservation; terminal teardown и authoritative termination guards.
Список приглашённых не является установлением личности. Display title не меняет
календарный context, пути, время или идентификаторы.

Точные layout tokens и поведение находятся в [design.md](design.md) и specs.
Нативный split divider имеет собственный1pt slot; actions child сохраняет прежние
позицию и ширину, а separator принадлежит тому же accessory. Source relationship
не выдаётся за новый runtime measurement или доказанную compositor occlusion.

## Подтверждения и ограничения

Владелец принял divider в beta23 для сообщённого использования и разрешил
финализацию документации и локальной beta. UI заморожен. Beta22 сохраняется
как неустранённый painted gap; прежние aligned bounds не были painted PASS.
Общий parity18, pointer/drag/keyboard/VoiceOver/Spaces, macOS15 fallback,
физическое аудио и long-run UAT остаются отдельно непроверенными.

Текущий release scope — только документация/metadata, выбранные безопасные проверки
и настоящий App+worker package. Полная suite содержит EventKit/audio/model/native
побочные эффекты и не запускается без отдельного разрешения. Непроверенные задачи
не отмечаются и change не архивируется. Подробнее — verification и tasks.
