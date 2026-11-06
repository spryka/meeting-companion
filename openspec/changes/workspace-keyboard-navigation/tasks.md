# Workspace keyboard navigation — единый план

Цель и критерий готовности: выполнить K01–K08 из `specs/workspace-keyboard-navigation/spec.md` через существующие workspace/form/search/playback routes. Готовность требует проверок production callers, независимого ревью и реальных keyboard/focus/accessibility UAT; сборка и source PASS не заменяют UAT.

Границы: согласованные proposal/spec/design сохраняются. Только App, относящиеся к нему тесты и `[Unreleased]`; без изменений storage/ASR, новых зависимостей, глобальных monitors, permissions и persistence keys. Записи, транскрипты и существующие правки сохраняются. Release, установка и архивирование отдельно.

Согласование этапов: **ожидается явное утверждение владельца**. До него продуктовый код не менять. После утверждения выполнять этапы последовательно без повторного согласования обычных технических решений внутри этих границ.

Исходное состояние: HEAD `e46021480bc4eba4a3b51be1b43e653f38650031`, рабочая копия dirty. Пересекающиеся правки уже есть в `TranscriptReviewWindow.swift`, `ProductionCompositionTests.swift`, `VisualFidelityTests.swift` и `CHANGELOG.md`; сам SDD untracked. Baseline сохранён в `$BB_THREAD_STORAGE/workspace-keyboard-navigation-baseline-20261106T100312Z/`: `git-status.txt`, `head.txt`, `preexisting.diff`, `files.tar` (четыре App entrypoints, App tests с untracked-файлами, CHANGELOG и исходный SDD), `sha256.txt`. Чужие изменения не откатывать и не включать в свой diff.

## Границы этапов и ревью

1. **Форма и поиск** — задачи 1.1, 2.1–2.3. Наблюдаемый результат: native menu/⌘N/⌘F работают через один guarded route, сохраняют ввод и session, поиск доступен в narrow layout. Ревью R1 после GREEN и host-проверок.
2. **Плеер и приоритет ввода** — задачи 3.1–3.3. Наблюдаемый результат: пробел и ±5 секунд работают из обеих навигационных поверхностей однократно, сохраняя native input/control priority и playback identity. Ревью R2 после GREEN и host-проверок.
3. **Навигация панелей и интеграция** — задачи 4.1–4.2, 5.1–5.2. Наблюдаемый результат: стрелки используют текущую выдачу и настоящий focus, сохраняют библиотеку в narrow layout, клавиатурный scroll останавливает follow без остановки audio. Ревью R3 включает весь diff задачи, взаимодействие этапов и итоговые обязательные проверки.
4. **Нативная приёмка** — задачи 5.3–5.4. Реальные key events, раскладки, layout и VoiceOver; непроверенное остаётся открытым. Если UAT потребует правок, повторить затронутые проверки и вернуть их reviewer соответствующего этапа.

На R1/R2/R3 — новый независимый read-only reviewer `gpt-6.1-sol`, reasoning `high`, без истории ведущего. Бриф: требования, baseline, точный task-only diff с новыми файлами, хеши и результаты проверок. Проверяемую версию заморозить на время ревью. Для ремонта использовать того же reviewer; максимум два раунда на этап. Каждую находку разобрать с доказательством. Блокирующие находки запрещают зависимый этап; `[x]` ставить только после проверки и соответствующего ревью.

## 1. Контракт и границы

- [ ] 1.1 Согласовать proposal/spec/design с владельцем; перед кодом сохранить baseline существующих правок и подтвердить ADR review из adr.md. Новые root ADR не требуются.

## 2. Команды формы и поиска

- [ ] 2.1 Сначала воспроизвести падающими App/host-тестами `⌘N`, `⌘F`, повторный вход, narrow search и blocked/stale modal dispatch (K01, K02, K04, K07). Использовать изолированные defaults/appData/recordings.
- [ ] 2.2 Подключить команды формы и существующего поиска через один guarded workspace route, с native menu labels, фокусом и сохранением ввода; довести тесты до GREEN (K02, K04, K08).
- [ ] 2.3 R1: независимое read-only ревью этапа «Форма и поиск»; записать reviewer ID, хеши/diff, исходный отчёт, разбор находок и счётчик ремонтов.

## 3. Плеер и приоритет ввода

- [ ] 3.1 Подтвердить RED для пробела/relative seek: обе панели, text/IME/native-control priority, key repeat, unavailable audio, границы ±5 секунд, paused/playing/rate и смена result identity (K03, K07).
- [ ] 3.2 Подключить пробел и `←` / `→` к существующему playback controller, menu/keyboard admission и одноразовому dispatch; подтвердить GREEN без запуска ASR (K03, K08).
- [ ] 3.3 R2: независимое read-only ревью этапа «Плеер и приоритет ввода», включая взаимодействие с командами формы/поиска; записать reviewer ID, хеши/diff, исходный отчёт, разбор находок и счётчик ремонтов.

## 4. Стрелки и владение панелями

- [ ] 4.1 Получить RED через production selection/scroll boundaries: filtered/empty/boundary/no-selection list, быстрые A→B→C с late completions, сохранение focus, narrow list и остановка follow при keyboard scroll (K01, K05, K06).
- [ ] 4.2 Реализовать навигацию `↑` / `↓` по текущей выдаче и прокрутку текста по реальному focus; сохранить native Tab/Shift-Tab, модальные guards, данные и прежние стрелки ползунка; довести проверки до GREEN.

## 5. Проверка и приёмка

- [ ] 5.1 Добавить пользовательское изменение под `[Unreleased]`; выполнить `swift build -c release`, `swift test`, `bash scripts/check-python-free.sh`, `bash scripts/check-module-boundaries.sh`, `swift skills/local-audio-transcriber/scripts/find-recording.swift --self-test`, `openspec validate workspace-keyboard-navigation --strict` и `git diff --check`. Записать результаты и исключения.
- [ ] 5.2 R3: передать готовое изменение независимому read-only reviewer с чистым контекстом, без истории/выводов writer; проверить этап навигации, взаимодействие всех этапов и суммарный task-only diff; разобрать каждое замечание, выполнить не более двух раундов исправлений и сохранить исходные отчёты.
- [ ] 5.3 На нативном host выполнить реальные нажатия всех четырёх сочетаний и стрелок, смену focus кликом и Tab/Shift-Tab, обе раскладки, filtered library, длинный текст/follow, поля ввода, Settings/editor/rename/recording form и wide/compact/narrow layout; проверить доступность с VoiceOver. Не заменять key UAT прямыми model-вызовами или bitmap. Непроверенные пункты оставить открытыми; данные и запись не затрагивать.
- [ ] 5.4 Получить приёмку проверенного поведения. Release/установку и архивирование выполнять отдельно; не объявлять strict validation или code review доказательством keyboard UAT.

## Текущее состояние и доказательства

- Шаг: план подготовлен; следующий шаг — явное утверждение этапов владельцем, затем 1.1 и RED для 2.1. Реализация не начата.
- Подготовка: прочитаны CONTRIBUTING, SDD, ADR0001–0007, действующий `single-current-transcript` spec и относящиеся production routes/host-тесты. ADR review подтверждён, новых root ADR не требуется.
- Найденные границы: `RecorderAppDelegate` → `RecorderViewModel` admission/load; поиск и grouped cards в `RecordingHistoryView`; playback/slider/follow в `TranscriptReviewWindow`. Native control priority и keyboard selection должны сохранять эти routes.
- Проверки: `openspec validate workspace-keyboard-navigation --strict` — PASS (exit 0), до реализации. Build/tests/keyboard UAT ещё не выполнялись.
- Ревью: R1/R2/R3 не запускались; ремонты 0/2 для каждого этапа. Находок пока нет.
- Открыто: все обязательные проверки 5.1, все native keyboard/focus/layout/VoiceOver UAT 5.3 и приёмка 5.4.
- Время: baseline и checkpoint подготовки — 2026-11-06T10:03:12Z; точное время начала чтения не зафиксировано. Первая рабочая версия и завершение отсутствуют; ожидание утверждения начинается после передачи плана.
