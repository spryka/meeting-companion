## 1. Baseline и перенос

- [x] 1.1 Прочитать README пакета, AGENTS.md, CONTRIBUTING.md, действующие ADR и текущие specs/changes; перенести только speaker-review-ui в отдельную ветку/worktree от свежего master, сверить drift с baseline.
- [x] 1.2 Сверить кликабельный reference/index.html и coverage.md с native компонентами; сохранить оба входа, полные метаданные и существующие действия workspace.
- [x] 1.3 Запустить `openspec validate speaker-review-ui --type change --strict` в target checkout, исправить реальные ошибки документов без ослабления требований.

## 2. Проверяемая модель разбора — test first

- [x] 2.1 Написать падающие Swift-тесты: все голоса/поздний участник, одинаковые localID разных sources, одинаковые имена разных голосов, порядок document.turns и mixed/manual группы.
- [x] 2.2 Реализовать минимальную projection в текущем review model: стабильные group/turn identity, список/выбор, сессионные пропуски/прогресс/возврат; сделать тесты зелёными.
- [x] 2.3 Написать падающие тесты общих подсказок: manual имя в любой реплике, частичная группа, NFC/краевые пробелы/регистр, повторные attendees, освобождение имени после переименования и повторный ручной ввод.
- [x] 2.4 Реализовать одну общую функцию фильтрации для обоих входов, без EventKit/network refresh; подтвердить зелёные тесты.

## 3. Назначение и сохранение — test first

- [x] 3.1 Добавить падающие сценарии one/remaining/all-group, including manual text overrides, сохранение manual имени по умолчанию, явная замена, одно имя для разных голосов и неизменённое имя/no-op.
- [x] 3.2 Подключить существующие previewRemainingAssignment/previewGroupAssignment и assignSpeakerName(preview:displayName:), без нового store/writer; показать реальные counts и примеры точечной правки.
- [x] 3.3 Добавить падающие сценарии Save failure, stale revision/result/draft, двойной Confirm, чужой recording identity, поздний callback, неразрешённый ввод при navigation/retry/close.
- [x] 3.4 Реализовать guards и явную ошибку без автоматического обхода, сохранить ввод/saved состояние; переход к следующему и прогресс только после успеха. Сделать проверки зелёными.
- [x] 3.5 Проверить reopen с диска, отображение/search/export актуальных имён и сохранность текста, recognition, времени, overlaps и чужих resultID. Не добавлять saved undo или миграцию.

## 4. Прослушивание — test first

- [x] 4.1 Написать падающие fake-transport тесты: play только после успешного seek, stop на end, pause/resume, switch voice/fragment, нулевой interval, отсутствующий микс и stale seek/current callbacks.
- [x] 4.2 Добавить минимальный interval lifecycle к существующему player; переиспользовать mix current result, не создавать второй player или voice-isolation pipeline. Подтвердить тесты.

## 5. Native UI и соответствие макету

- [x] 5.1 Встроить общий экран в правую область workspace; сохранить библиотеку, данные встречи, toolbar/player и возврат к позиции текста/выбранной реплике.
- [x] 5.2 Сохранить локальную модалку назначения, single/remaining preview и явный Confirm; добавить переход в выбранный голос с переносом имени как draft без сохранения.
- [x] 5.3 Реализовать список/детали, явный overwrite, назначение/следующий/пропуск, завершение и повторный просмотр списка с текстами reference/coverage.md.
- [x] 5.4 Реализовать компоновку по доступной ширине панели: узкая шапка, список/детали поочерёдно, перенос длинных кнопок и независимая прокрутка; сохранить доступ к библиотеке через существующую native навигацию.
- [x] 5.5 Вручную сверить HTML на 360/390/768/1024/1440 px и native fitting layout, короткую высоту, длинные/Unicode имена, 1/7/16 голосов и длинный список реплик. Зафиксировать расхождения; source-only проверки не считать visual PASS.
- [ ] 5.6 Проверить клавиатуру/VoiceOver: focus после входа/возврата, Tab, Escape/Cancel, disabled причины, прогресс, доступные имена и остановку playback при уходе.

## 6. Regression, ревью и приёмка

- [x] 6.1 Выполнить `openspec validate speaker-review-ui --type change --strict`, `swift build -c release`, `swift test`, `bash scripts/check-module-boundaries.sh` и `swift skills/local-audio-transcriber/scripts/find-recording.swift --self-test` в подходящем Xcode/Metal окружении.
- [x] 6.2 Провести независимое ревью связного diff и сверку requirements ↔ native UI ↔ reference; каждое замечание оценить с evidence, максимум два раунда исправлений до отчёта о незакрытом.
- [ ] 6.3 Провести native UAT на синтетической длинной встрече с поздним участником, частичными именами, overlapping репликами, ошибкой сохранения и reopen. Реальные записи не включать в fixtures.
- [x] 6.4 Обновить CHANGELOG [Unreleased], описать выполненные проверки и остаточные ограничения; получить приёмку перед архивированием. Установка и выпуск — отдельное разрешение.

## Проверка реализации — 2026-11-17

- Baseline пакета совпал с обновлённым origin/master: 6529b73e343531545f29a5a0919cbdacba00e428. Перенесён только этот change; reference/index.html сохранён побайтно.
- Для projection, suggestions, сохранения/admission и playback получены ожидаемые RED до реализации, затем GREEN. Пять замечаний независимого ревью закрыты регрессионными тестами; итог code/reference review — PASS после двух раундов исправлений.
- swift build -c release, OpenSpec strict validation, module boundaries и recording-finder self-test — PASS.
- Полный swift test --no-parallel — PASS: 614 Swift Testing tests и 14 XCTest tests. Assertions и лимит времени не ослаблялись.
- В обычном swift test остаётся нестабильный timing-gate W08: открытие 5760 реплик заняло 5.924933208 s при лимите 5 s. Тот же тест прошёл за 0.74137 s в последовательном наборе и за 0.703334084 s отдельно. Это ограничение воспроизводимости общего параллельного прогона, не PASS стандартной команды.
- Кликабельный HTML просмотрен на 360/390/768/1024/1440 px; реальные SwiftUI/AppKit-снимки — на тех же ширинах, light/dark, 1/7/16 голосов, 80 реплик, поздний голос, длинные Unicode имена, короткое окно и прокрутка до нижних действий. Проверены normal/overwrite/CAS-error/dirty-resize/completion render states. Native render использовал программные переходы модели; он не подтверждает физические клики.
- Fake transport проверил порядок seek/play, pause/resume, end, invalid intervals и late callbacks. Реальный muted AVPlayer проверил остановку по AVPlayerItem boundary. Слышимость микса и перекрытий не проверялась.
- Reopen, saved export, сохранность recognition/text/identity/timestamps и ошибочные commits проверены автоматизированно на синтетических данных. Пользовательские записи не использовались.

Открыты 5.6 (ручная клавиатура/VoiceOver), 6.3 (полная native UAT владельца) и 6.4 (приёмка; CHANGELOG уже обновлён). AX tree тестового процесса содержит только root, поэтому AXPress/VoiceOver не объявлены проверенными. Установка, выпуск и архивирование не выполнялись.

## Приёмка владельцем — 2026-11-18

Владелец проверил native приложение на своих встречах, принял сборку 86 после исправления оформления и сдвига при Play/Pause и явно разрешил merge в master и официальный beta-релиз. Это согласование закрывает приёмку 6.4; оставшиеся физические проверки 5.6 и полная синтетическая ручная матрица 6.3 не объявляются выполненными. Ограничения приняты к выпуску; новые блокирующие gates не вводятся.

- Финальные визуальные проверки: idle/playing/paused, light/dark, wide/narrow; X текста и времени до/после Play совпадает в восьми измерениях реальных native PNG.
- На сборке 85 полный `swift test --no-parallel` прошёл: 614 Swift Testing и 14 XCTest. На финальной визуальной правке сборки 86 дополнительно прошли 17 связанных тестов и native render; версия/build — единственные продуктовые изменения для публичного кандидата 87.
- Независимое ревью итогового кода и дополнительных визуальных исправлений — PASS. Source/voice identity, CAS/admission, timestamps и прежний playback сохранены.
- Слышимость аудио, физические keyboard/VoiceOver и вся матрица ручной синтетической UAT отдельно не подтверждены. Автоматические regression/native-render проверки не подменяют эти проверки.
- Принято уточнение оформления относительно HTML: внутренний отступ реплики постоянен, ширина Play/Pause иконки фиксирована, поэтому текст и время не сдвигаются при запуске. Сам принятый HTML сохранён как исходный reference.
