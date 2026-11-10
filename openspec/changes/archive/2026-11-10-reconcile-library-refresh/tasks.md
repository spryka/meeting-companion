## 1. Contract

- [x] 1.1 Согласовать proposal, сценарии и design до реализации по CONTRIBUTING.md (владелец: «Да, реализуй», 2026-11-10).

## 2. Regression and implementation

- [x] 2.1 Написать и подтвердить падающий тест: внешнее удаление standard/flat-записи, затем refresh убирает строку; пустая библиотека очищает список. RED: 4 repository cases и 2 App cases, ожидаемые оставшиеся строки/selection/session; остальные прежние тесты прошли.
- [x] 2.2 Исправить shared merge; проверить partial/missing root, work/unsaved/concurrent protection, границы root и восстановление.
- [x] 2.3 Через App tests подтвердить очистку исчезнувшей selection/session и сохранение существующего документа/ввода; реализовать минимальную очистку после manual refresh. Дополнительный RED для presenting row, затем GREEN: 39 tests в 3 suites вместе с Trash.

## 3. Verification

- [x] 3.1 Проверить итоговый diff с учётом чужих локальных правок, обновить CHANGELOG.md. Изменены только refresh/selection и их tests; прежние удаления/правки в рабочем дереве сохранены, git diff --check прошёл.
- [x] 3.2 Выполнить openspec validate reconcile-library-refresh --strict, swift build -c release, swift test и обязательные проверки AGENTS.md. Release build PASS; полный swift test -c release --skip-build --no-parallel PASS: 559 tests / 47 suites. Python-free, module boundaries и recording finder self-test PASS. В первом общем прогоне 2 плавающих UI/тайминг-сбоя; оба отдельно прошли без изменения tests/assertions/timeouts.
- [x] 3.3 Владелец проверил установленную beta.36 build 73 и подтвердил "работает!" 2026-11-10. Native UI startup и ⌘R smoke агента PASS, прежний документ сохраняется. Подпись/backup/recordings manifest проверены. Автоматические App/native UI tests прошли. Отдельный synthetic UI replay, capture/model preparation/transcription агентом не проводились и не объявляются выполненными; результат принят владельцем для публикации.
