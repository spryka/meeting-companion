## 1. Подготовка

- [x] 1.1 От свежего master создать отдельную ветку/worktree, импортировать только meeting-reminder-ui; сверить AGENTS/CONTRIBUTING, ADR и relevant specs. Сохранить чужой dirty diff, не трогать pipeline/release файлы.
- [x] 1.2 Проверить showReminder/MeetingReminderView/startMeeting, calendar ordering/fallback, short cancellation, guards и существующие тесты; HTML использовать как visual reference, не как lifecycle implementation.

## 2. Native UI

- [x] 2.1 Реализовать idle/recording композицию по design.md: реальные title/time/elapsed, корректное short-recording пояснение, primary/secondary actions, light/dark и accessibility. Убрать fixed 212 pt; высота по содержимому до экранного максимума, при переполнении scroll текста с постоянно доступными действиями и visibleFrame clamp без перекрытия controls капсулы.
- [x] 2.2 Сделать отдельный chooser без поиска: ограниченная высота, scroll для 12+, галочка, «Без встречи», прежний набор кандидатов/fallback. Открытие не меняет frame reminder, закрытие родителя закрывает chooser.
- [x] 2.3 Сохранить общий guarded startMeeting, expectedSessionID и stop-before-start; минимально доработать общий путь, без writer/session/queue. Актуальность полного выбранного контекста и guards проверяются до stop и перед новым capture после ожиданий; skip/timeout не меняют capture, acknowledgement и сроки прежние.
- [x] 2.4 Ошибки завершают попытку с понятной причиной в terminal reminder с единственным «Закрыть», видимым и при скрытом workspace; новый ручной вход заново проверяет session/meeting/admission. Не добавлять автоматические повторы, fallback-пути и восстановление workflow. При stop error не запускать запись, чужую session не останавливать, данные сохранять по прежнему lifecycle; старый outcome не меняет новое UI/session.

## 3. Проверки и передача

- [x] 3.1 Для изменённой логики сначала получить ожидаемое падение регрессии: выбор без старта, skip, stale session, invalid calendar candidate, repeated accept, stop/start errors, short boundary 9/10 секунд. Переиспользовать существующие seams и синтетические fixtures.
- [x] 3.1a Проверить отсутствие автоматических повторов/восстановления после отказа; новый явный вход использует актуальную identity, stop error не вызывает start, данные прежней записи сохраняются согласно lifecycle.
- [x] 3.1b Получить red → green для held-stop: Settings/native modal, deleted/changed same-id meeting и другая session во время ожидания; новая запись не запускается, прежние данные/processing сохраняются. Проверить видимую причину rejection/failed start при скрытом workspace и изоляцию старого outcome.
- [x] 3.2 На native Mac проверить два состояния, 1/12+ кандидатов, «Без встречи», длинные названия и overflow с доступными действиями, pointer/scroll/keyboard, Escape/outside-click и закрытие chooser при timeout. Проверить terminal ошибку при скрытом workspace, неизменность frame при открытии chooser, отсутствие пересечения с capsule и освобождение panel/presenter. Завершить ручную проверку напоминаний в установленной beta.41.
- [x] 3.3 Выполнить `openspec validate meeting-reminder-ui --type change --strict`, релевантные тесты и обязательные проверки AGENTS; обновить CHANGELOG [Unreleased]. Явно записать непроведённый native UAT.
- [x] 3.4 Передать итоговый diff и результаты проверок на review. Не архивировать до приёмки; установка и выпуск не входят в change.

## Итог проверки

Ручная проверка напоминаний в beta.41 завершена 2026-11-12. Native regression suite:
12 PASS; полный обычный `swift test`: 594 PASS. Release build, module boundaries,
Python-free, recording finder и strict OpenSpec прошли. Независимое ревью кода
и native-поведения: PASS. Расширенные проверки physical VoiceOver,
compositor/glass и нескольких мониторов/fullscreen не проводились;
они не входят в проверенный объём выпуска 2.0.0.
