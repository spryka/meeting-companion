# Сохранение правок: сводная верификация блока 2.1 (RED suite)

Дата: 2026-10-30. Статус задачи 2.1: выполнена полностью (все подблоки 2.1a–2.1f приняты независимым ревью Sol).

## Матрица сценариев и свидетельств

| Подблок | Сценарии спецификации | Тестовый файл | Результат / Свидетельства |
|---|---|---|---|
| **2.1a** | Reopen edited result, revision 0 при отсутствии, инкремент ревизии, неизменность исходников и аудио | `TranscriptEditsRepositoryTests.swift` | 2 RED (`.notImplemented` на skeleton) / `verification-2.1a.md` |
| **2.1b** | Existing external edit: конфликт ревизии и overrides; конфликт содержимого при равных revision/size/mtime | `TranscriptEditsConflictTests.swift` | 2 RED (prerequisite `.notImplemented`, строгий matcher `.conflict`) / `verification-2.1b.md` |
| **2.1c** | Existing external edit: внешнее создание при открытом отсутствии; внешнее удаление (запрет silent recreate) | `TranscriptEditsPresenceConflictTests.swift` | 2 RED (prerequisite `.notImplemented`, строгий matcher `.conflict`) / `verification-2.1c.md` |
| **2.1d** | Failed save + retry: сбой атомарной замены, валидация staging до throw, сохранность диска, retry со следующей ревизией | `TranscriptEditsSaveFailureTests.swift` | 2 RED (prerequisite `.notImplemented`, строгий matcher `InjectedSaveError`) / `verification-2.1d.md` |
| **2.1e** | Second application writer: отказ второму процессу (`lockDenied`), normal release, kill (`SIGKILL`), изоляция записи B | `TranscriptEditsLockTests.swift` | 2 RED (prerequisite `.notImplemented` дочернего процесса) / `verification-2.1e.md` |
| **2.1f** | Undo и version isolation: отмена одиночной/групповой правки в новой ревизии, независимость версий A и B, стек undo сессии | `TranscriptEditsUndoTests.swift` | 2 RED (prerequisite `.notImplemented`, точный matcher `noUndoHistory`) / `verification-2.1f.md` |

## Итог и ограничения

- **12/12 тестов блока 2.1**: честный runtime prerequisite RED (`.notImplemented`), ошибки компиляции отсутствуют.
- **Reader (`TranscriptDocumentTests`)**: 16/16 GREEN.
- Никаких утверждений о готовности логики (no GREEN claims): сериализация, атомарная запись, блокировки flock, отпечатки CAS и стек undo НЕ реализованы и запланированы в задаче 2.2.
- Задача 1.0 остаётся открытой `[ ]`. Задача 2.2 остаётся открытой `[ ]`.
