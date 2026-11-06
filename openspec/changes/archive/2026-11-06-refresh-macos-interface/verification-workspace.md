# W01–W08: границы проверки workspace

Source реализован и прошёл ограниченное independent review; это не полный
physical/UAT PASS. Один workspace переиспользует current session/repositories,
CAS/locks, safe export и playback. Old results/edits/audio/unknown metadata сохранены.

| Scope | Production / retained regression |
|---|---|
| W01/W02 | Delegate showWorkspace условно загружает и явно показывает existing host; request/key/close generations защищают hidden/stale reacquisition; narrow list/detail сохраняют selection/session |
| W03 | Saved-edits search off MainActor, generation rejection, ENOENT отдельно от stat failure, own contained flat TXT |
| W04 | Exact UTF-8 no-op, save/CAS/atomic failure; remaining anchor/source/voice/manual replacement preview/apply; input/modal admission и late completion |
| W05 | Current exact mix без fallback, interval/follow, missing/error, bounded waveform cancellation |
| W06 | Saved snapshot copy/export, request identity/cancel/overwrite/reentrancy/protected destinations; injected panel runner/sink не являются physical clipboard/panel |
| W07 | Optional displayTitle atomic latest-entry write/reload, неизвестная точная metadata, capture/admitting/queued exclusion, flat guard и exact raw retry |
| W08 | Synthetic long document/streaming transport и duration formatting; это не eight-hour audio RAM/latency UAT |

Все open routes — list/status/Dock/capsule — сходятся в existing workspace.
Presentation при explicit Open сохраняет input/session даже при отклонённой
загрузке. Capsule скрывается только после actual accepted target load; cached
current/failure nil не считается outcome новой попытки.

Групповой preview и commit используют тот же исходный source/voice predicate,
stable turns suffix и bound target name/revision/snapshot. Более ранние реплики,
другой источник и текст не меняются. Save error сохраняет input; GUI saved undo
нет, native field undo и Cancel остаются. Rename меняет display data, не paths/context.

Historical full-suite nested SwiftPM sandbox/AAC failure и исходный
module-boundary failure сохранены; report-only adapted checker не считался
PASS исходного script. Native services в раннем test host были недоступны;
exit0 без complete summary не считался PASS. Новые safe selected results не
устраняют эти исторические gaps автоматически.

Реальные pointer/keyboard/focus/scroll/save panel/clipboard/Quick Look,
VoiceOver/contrast/reduced motion, Spaces/monitors/macOS15 fallback и физический
long audio UAT остаются WAITING_UAT. Owner beta23 divider acceptance относится
только к сообщённому использованию. Current final source checks имеют complete summaries ниже; все unchecked compound tasks сохранены.

## Текущие автоматические проверки finalization

Свежая release build завершена. Выбранные tests:194 Core/Application в21suites,
5pure pipeline assembly и3pure App (всего202), все с complete summaries.
Python-free, оригинальный structured module-boundary checker и Swift finder
self-test завершены успешно в утверждённом scoped context. Это current selected
проверки, не full suite и не runtime UAT. Исходники production/tests/CI неизменны
относительно принятой beta23; настоящие App+worker/signature/package результаты
фиксируются отдельно в release audit. Historical failures и NOT_RUN выше сохранены.
