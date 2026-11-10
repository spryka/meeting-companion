# Checkpoint

Цель: ⌘R убирает исчезнувшие на диске записи из списка без перезапуска.

Наблюдение: до перезапуска оставалось 79 строк, на диске 15. `refresh` только
добавляет scanned entries в entriesMap. Основной L02 явно запрещает удаление
отсутствующих строк. Пользователь запросил исправление; подготовлена замена L02.

Артефакты: proposal.md, specs/library-refresh/spec.md, design.md, adr.md, tasks.md.
Корневые ADR0001–0007 прочитаны с учётом частичных supersession; новых ADR нет.
Активных изменений до начала этой задачи не было.

Контракт согласован владельцем: «Да, реализуй», 2026-11-10. Добавлены regression
tests в LibraryRefreshTests и LibraryRefreshCommandTests. RED-запуск был прерван
вместе с turn до завершения сборки; повтор library-refresh-red-resumed.log
подтвердил ожидаемые падения 4 repository cases и 2 App cases
(оставшиеся строки/selection/session).
Реализованы prune в shared repository и guarded cleanup selection в AppMain.
Добавлены protection/concurrency/root/error и input-during-scan tests.
Первый GREEN: library-refresh-green.log. Дополнительный RED input-presenting row:
library-refresh-input-red.log. Итоговый GREEN: library-refresh-final-focused.log,
39 tests в 3 suites (LibraryRefreshTests, LibraryRefreshCommandTests,
RecordingTrashTests). Устаревший scan отсекается до callback на MainActor и
повторно под repository lock. Ввод, появившийся во время scan, сохраняет строку
и presenting view до следующего разрешённого refresh.
Всегда запускать SwiftPM с DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer:
глобальный xcode-select указывает на CommandLineTools без metal.
Python-free, module boundaries, recording finder self-test и strict OpenSpec
validation прошли на итоговых исходниках. Release build прошёл (135.45 s):
library-refresh-release-build.log. Первый полный test run с --skip-build:
7 ModelVendor, 49 Pipeline и 256 Core tests прошли; App (247 tests) завершился
с 2 failures: eight-hour synthetic open >5 s (7.08 s) и отсутствующий library
view при setup arrows cleanup last/up. Затронутые refresh tests прошли.
Изолированный повтор обоих сценариев прошёл без изменений тестов: open 1.31 s,
все 8 cases arrows cleanup. Логи: library-refresh-full-tests.log и
library-refresh-failure-recheck.log. Полный повтор с явным --no-parallel прошёл:
library-refresh-full-serial-tests.log. Всего 559 tests / 47 suites: ModelVendor 7,
Pipeline 49, Core 256, App 247. Порог времени и assertions не менялись.
В последовательном прогоне synthetic 8h open = 0.454 s, 8 arrows cases PASS.
CHANGELOG обновлён, итоговый diff просмотрен, git diff --check прошёл.

До начала задачи уже изменены AppMain.swift, InterfaceStyle.swift,
RecorderAppDelegate.swift, RecordingHistory.swift, TranscriptReviewWindow.swift,
RecordingHistoryRepository.swift, RecordingSessionService.swift и AudioCapture.swift.
Эти правки сохранять. Scope нового кода: shared refresh, guarded manual refresh
и соответствующие LibraryRefreshTests/LibraryRefreshCommandTests.

Синтетические fixtures только во временных папках. Пользовательские записи,
установленный bundle и разрешения не затрагивать. Установка отдельно.

Итог реализации: автоматическая проверка завершена. Прежние локальные изменения
сохранены. Параллельный общий прогон имеет два выявленных плавающих UI/тайминг-сбоя,
их исправление в этот change не добавлялось.

## Local installation, 2026-11-10

Владелец отдельно разрешил установку: «давай уж установим». CFBundleVersion
увеличен с 72 до 73, SemVer остаётся 2.0.0-beta.36. scripts/build-app.sh и
check-bundle.sh прошли; прежний designated requirement выполнен новым bundle.
Перед заменой приложение/CLI/worker остановлены. Staged bundle и установленная
копия побайтно совпали с dist; прежний bundle сохранён для отката, его путь —
install-rollback-path.txt в thread storage. Неопределённых результатов замены нет.

После запуска через native UI PID 96181 указывает на установленный executable
в /Applications. Info.plist сообщает build 73, SHA256 app executable совпадает
с dist (311d935a11bc458168863c97130a45448df0988b049e631c63a02f48ad35a9e2).
Native UI показывает 15 записей; ⌘R отрабатывает и сохраняет выбранный документ.
343 filesystem entries библиотеки сохранили identity/size/mtime до и после
установки/запуска; служебные .DS_Store исключены из сравнения. Разрешения не
сбрасывались, прежняя подпись сохранена. Публикации/commit не было.

Внешнее удаление синтетической записи на установленной сборке вручную не
проверялось; covered автоматическими regression tests. Новая запись,
подготовка моделей и транскрипция после установки не запускались.
После пользовательской проверки владелец подтвердил "работает!" и разрешил
публичную бету. Change закрыт 2026-11-10, L02 синхронизирован с основным spec.
