# P01–P08: границы проверки настроек

Source реализован и прошёл ограниченное independent review; полный physical UAT
остаётся WAITING_UAT. Settings теперь одна modal в workspace/форме по ADR0007,
не отдельное окно. Source review не доказывает pointer/focus/render.

| Scope | Сохранённая production boundary | Остаток |
|---|---|---|
| P01 | Общий model-owned Settings state, все entrypoints, повторный вход/late dismiss, input admission | Native overlay, keyboard/focus/background blocking |
| P02 | Theme/follow, SMAppService register/unregister/status/error, updater check policy | Реальный login item, Sparkle, rendered disclaimer |
| P03 | Выбранный mic ID, unavailable/refresh, picker cancel/error, AEC/backend | Устройства, реальные picker/audio |
| P04 | Shared model check/prepare, latest-file/count/progress/terminal summary | Реальные модели/download/offline/preparation failures |
| P05 | После confirmation fresh service reads +pending handoffs/foreign/cancellation, sync reset commit; own flags не self-block | Реальное filesystem удаление кэша и задержка UI |
| P06 | Stable calendar IDs/filter, loading/denied/empty/guidance | EventKit/accounts/permissions |
| P07 | Visibility-owned monitoring, stale UUID/cancellation deadlines, stop при departure, form не autostart после Settings close | Реальные разрешения/levels/host visibility |
| P08 | Operation-specific guards и независимые capture/jobs; чужой modal dismiss не снимает Settings ownership | Полная rendered lock matrix |

Исторические целевые behavioral RED→GREEN покрывали commit admission, held
confirmation, current pending/running work, idle own flags, cancellation, actual
form callbacks и ручной title при смене встречи. Фикстуры clock/wait были исправлены
отдельно от production; import/compile/environment failures не считались RED.
В ранних fixtures nil calendar selection могла дойти до events при полном доступе;
фактическое чтение личных событий не установлено. Empty selection не устраняет
само eager EKEventStore construction: model-dependent helpers не запускаются в
release finalization. Новый production facade ради GREEN не добавляется.

Historical full suite/module-boundary/window dark-appearance failures сохранены.
Текущий approved inventory содержит только pure App checks и safe Core/pipeline
assembly; их текущие результаты приведены ниже.
Реальные reset/calendar/login/audio/model/permission flows в finalization NOT_RUN.

## Текущие автоматические проверки finalization

Свежая release build завершена. Выбранные tests:194 Core/Application в21suites,
5pure pipeline assembly и3pure App (всего202), все с complete summaries.
Python-free, оригинальный structured module-boundary checker и Swift finder
self-test завершены успешно в утверждённом scoped context. Это current selected
проверки, не full suite и не runtime UAT. Исходники production/tests/CI неизменны
относительно принятой beta23; настоящие App+worker/signature/package результаты
фиксируются отдельно в release audit. Historical failures и NOT_RUN выше сохранены.
