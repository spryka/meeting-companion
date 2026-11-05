# R01–R08 / M01–M04: границы проверки

Source реализован и прошёл ограниченные independent reviews. Физический audio,
Spaces/fullscreen/monitors, pointer/drag/keyboard/VoiceOver и busy update/quit
остаются WAITING_UAT. Библиотека и floating NSPanel используют одни shared services.

| Production boundary | Имеющаяся synthetic/source проверка | Не доказано ею |
|---|---|---|
| RepresentedObject UUID +explicit command intent → delegate/model/service | Missing/stale identity rejection, matching stop/mute, не изменять successor | Настоящий tray click/устройства |
| New recording → существующая форма | Сохранённый unavailable mic, ошибка старта, success callback только после accepted start | Capture permissions/качество |
| Starting/saving до processing, nondismissible transition | Held factory/start/stop, old timer не скрывает новый job | Native settling/clipping |
| Short cancel до10 /save от10 | Явные retained form intents; ordinary stop не удаляет короткий capture, trash failure сохраняет originals/error | Реальная короткая запись |
| Terminal feedback job/generation/deadline | Same-URL retry, accepted handoff/queued/working, Hide/reminder, поздний callback | Полная native capsule matrix |
| Stage progress и PCM echo units | Current-stage fraction и проценты вместо секунд, unknown totals/warnings | Реальная длительность модели |
| Panel position/size/clamp | Pure geometry/clock checks, independent controller source | Drag/display/focus/Spaces/accessibility |

Оба клика status item ведут к одной NSMenu. Disabled items не заменяют
execution-time admission; initial attachment/starting/stopping/saving/admitting,
preparing/checking/queued/processing не выдаются за idle. Одновременная запись и
прежняя обработка имеют разные identities; скрытие UI не отменяет работу.
Live autostart в Settings и первоначальная конфигурация сохранены.

Исторический full suite имел nested SwiftPM sandbox_apply failure и afconvert AAC
failure; incomplete runner без summary не считался GREEN. Предыдущие native
timeout/noWindowsAvailable оставлены как остановки, не успех drag или render.
Удалён только obsolete transforming-window harness; independent panel не заменён им.

Finalization не запускает native host, capture, модель, реальное аудио, termination
или установку. Fresh safe check summaries/package проверяются отдельно; прежние
результаты не переносятся на final artifact как текущий full PASS.

## Текущие автоматические проверки finalization

Свежая release build завершена. Выбранные tests:194 Core/Application в21suites,
5pure pipeline assembly и3pure App (всего202), все с complete summaries.
Python-free, оригинальный structured module-boundary checker и Swift finder
self-test завершены успешно в утверждённом scoped context. Это current selected
проверки, не full suite и не runtime UAT. Исходники production/tests/CI неизменны
относительно принятой beta23; настоящие App+worker/signature/package результаты
фиксируются отдельно в release audit. Historical failures и NOT_RUN выше сохранены.
