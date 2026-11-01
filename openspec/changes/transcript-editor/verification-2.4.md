# Пользовательская документация и верификация состояний: блок 2.4

Дата: 2026-10-31. Статус задачи 2.4: выполнена полностью, принято независимым ревью Sol после 2 fix cycles. Свидетельства: `W/2.4-final-review.md`.

## 1. Подготовленные документы
- `docs/transcript-editor.md`: Полное руководство по поведению ядра, обработке сбоев, конфликтов, блокировок, отмены и версионирования с явным разделением на верифицированное поведение Core и проектируемый интерфейс UI.
- `README.md`: Контекстная ссылка на архитектурную документацию редактора в секции «История».

## 2. Матрица соответствия: утверждения документации → тесты состояния Core

| Утверждение документации (`docs/transcript-editor.md`) | Механизм Core | Проверяющий тест Swift |
|---|---|---|
| **Коммит ревизии только после записи на диск** | Ревизия инкрементируется монотонно только после успешного атомарного коммита файла на диске | `TranscriptEditsRepositoryTests.testDurableEditsHappyPathReopenRestoresLatestState` |
| **Сохранение черновика при сбое сохранения** | При сбое staging/write старые байты сохранены, черновик вызывающего остаётся в памяти, retry со следующей ревизией успешен | `TranscriptEditsSaveFailureTests.testFailedSavePreservesPreviousEditsAndAllowsRetrySavingNextRevision` |
| **Сохранность при сбое при начальном отсутствии edits** | Сбой сохранения при отсутствующем файле не оставляет мусора на диске, retry успешен | `TranscriptEditsSaveFailureTests.testFailedSaveWithInitialAbsentEditsLeavesNoFileAndAllowsRetry` |
| **Очистка временных файлов staging** | Сбой при подготовке staging удаляет временный файл и сохраняет старый `edits.json` | `TranscriptEditsSaveTests.testPartialStagingWriteCleansUpTemporaryFileAndLeavesOldEditsIntact` |
| **Один писатель приложения на запись (`flock`)** | Второй процесс получает немедленный отказ `lockDenied`; падение процесса (`SIGKILL`) освобождает блокировку | `TranscriptEditsLockTests.testLockRejectsSecondProcessAndReleasesOnProcessDeath` |
| **Освобождение блокировки при завершении репозитория** | Вызов `releaseWriteLock()` освобождает OS flock для следующего процесса | `TranscriptEditsLockTests.testLockRejectsSecondProcessAndReleasesOnExplicitClose` |
| **Отказ второму репозиторию в том же процессе** | Повторное открытие того же каталога на запись в одном процессе отклоняется | `TranscriptEditsLockTests.testSeparateRepoInSameProcessIsDeniedWhileOtherHoldsLock` |
| **Освобождение блокировки при deinit репозитория** | Уничтожение экземпляра репозитория закрывает дескриптор и снимает flock | `TranscriptEditsLockTests.testDeinitReleasesLock` |
| **Идемпотентность захвата блокировки** | Повторный вызов `acquireWriteLock()` на том же экземпляре безопасен и идемпотентен | `TranscriptEditsLockTests.testRepeatedAcquireOnSameRepoIsIdempotent` |
| **Конфликт при внешнем создании файла** | Если файл был создан на диске между `loadEdits` и `save`, выбрасывается `conflict` | `TranscriptEditsPresenceConflictTests.testConflictWhenExternalWriterCreatesEditsAfterInitialAbsentLoad` |
| **Конфликт при внешнем удалении файла** | Если файл был удалён на диске между `loadEdits` и `save`, выбрасывается `conflict`, файл не пересоздаётся молча | `TranscriptEditsPresenceConflictTests.testConflictWhenExternalWriterDeletesEditsAfterInitialLoad` |
| **Конфликт при изменении содержимого с прежней ревизией** | Изменение байт файла при сохранении прежней ревизии выявляется побайтовым сравнением сырых данных и блокирует запись | `TranscriptEditsConflictTests.testConflictWhenExternalWriterChangesContentWithUnchangedRevision` |
| **Конфликт при изменении ревизии внешним писателем** | Внешнее изменение ревизии и переопределений на диске вызывает ошибку конфликта | `TranscriptEditsConflictTests.testConflictWhenExternalWriterChangesRevisionAndOverrides` |
| **Сохранение истории Undo при конфликте** | Обнаружение конфликта при выполнении `undo()` сохраняет стек отмены в репозитории | `TranscriptEditsUndoTests.testConflictDuringUndoThrowsConflictAndRetainsHistory` |
| **Сериализация конкурентных операций** | Очередь `operationGate` упорядочивает вызовы save и undo без гонок | `TranscriptEditsUndoTests.testConcurrentSaveThenUndoRespectsQueuedOrderAndRestoresCorrectState` |
| **Восстановление через новую ревизию в Undo** | Вызов `undo()` восстанавливает прежнее состояние в виде новой монотонной ревизии | `TranscriptEditsUndoTests.testUndoRestoresPreviousSavedStateAsNewRevisionAndDoesNotAffectOtherVersion` |
| **Атомарная отмена групповых правок** | Пакетный undo восстанавливает все затронутые реплики за одну операцию, не трогая другие версии | `TranscriptEditsUndoTests.testBatchOverridesUndoAtomicallyRevertsAllTurnTargetsAndLeavesOtherVersionUntouched` |
| **Сохранение операции в стеке при сбое Undo** | Сбой записи при отмене сохраняет действие в стеке undo для возможности повторной попытки | `TranscriptEditsUndoTests.testFailedUndoRetainsHistoryAndCanBeRetried` |
| **Очистка истории Undo при внешней перезагрузке** | Внешнее изменение файла и последующий `loadEdits` сбрасывают стек undo | `TranscriptEditsUndoTests.testExternalReloadWithChangedContentClearsUndoHistory` |
| **Отказ при исчерпании истории Undo** | Повторный вызов `undo()` при пустом стеке выбрасывает `noUndoHistory` | `TranscriptEditsUndoTests.testDoubleUndoThrowsNoUndoHistory` |
| **Закрепление открытой версии (Pinning)** | Сессия открывается с фиксированным `activeResultID`; появление новых версий не переключает открытую сессию | `TranscriptReviewSessionTests.testOpenedSessionPinsActiveResultIDWhenNewVersionIsPublished` |
| **Изоляция незавершённого retry/staging** | Сбои повторной обработки и наличие папок `staging-*/` не влияют на открытую сессию (синтетическая артефактная симуляция, не запуск Python) | `TranscriptReviewSessionTests.testFailedRetryStagingDoesNotAffectSessionOrAvailableVersions` |
| **Побайтовая неизменность исходников/миксов при retry** | Исходники, правки и аудиомиксы версии защищены от искажений при retry и смене версии (синтетическая артефактная симуляция, не запуск Python) | `TranscriptReviewSessionTests.testDirectBytePreservationBeforeNewPublishFailedStagingAndSwitch` |
| **Транзакционное переключение версии в Core** | Явное переключение обновляет метаданные на диске и восстанавливается при повторном открытии | `TranscriptReviewSessionTests.testExplicitVersionSwitchIsTransactionalAndPersistsToHistory` |
| **Синхронизация с живой историей через адаптер** | Явное переключение синхронизирует состояние сессии и живой истории через выбрасывающий авторитетный адаптер | `TranscriptReviewSessionTests.testRecordingHistoryIntegrationWithSessionSwitchAndReopen` |
| **Отказ при недоступной целевой версии переключения** | Попытка переключиться на несуществующую версию выбрасывает ошибку и не изменяет активную версию сессии | `TranscriptReviewSessionTests.testFailedVersionSwitchDoesNotMutateActiveSession` |
| **Откат переключения при повреждённых метаданных** | Повреждённый JSON истории на диске предотвращает смену версии и сохраняет байты на диске | `TranscriptReviewSessionTests.testActualAppHistoryMetadataCorruptSwitchThrowsKeepsSessionLiveDiskPrior` |
| **Откат переключения при некодируемых полях в истории** | Невалидное поле (например, `duration = .nan`) выбрасывает ошибку до записи на диск в авторитетной истории | `TranscriptReviewSessionTests.testActualAppHistoryNaNDurationSwitchThrowsKeepsSessionLiveDiskPrior` |
| **Безопасное чтение activeID из коллбэка** | Адаптер сохранения может безопасно обращаться к `session.activeResultID` без deadlock | `TranscriptReviewSessionTests.testCallbackReadsActiveIDWithoutDeadlock` |
| **Actor-hop из фонового потока** | Вызов `switchVersion` из `Task.detached` безопасно переключает контекст на `@MainActor` | `TranscriptReviewSessionTests.testBackgroundCallActorHop` |
| **Выбор последней версии без сохранения на диск** | При отсутствии сохранённого выбора открывается последняя опубликованная версия без автоматической записи на диск | `TranscriptVersionSelectionTests.testInitialNoChoiceSelectsLatestPublishedNonStagingResult` |
| **Восстановление сохранённого выбора** | Сохранённый выбор восстанавливается даже при наличии более новых версий | `TranscriptVersionSelectionTests.testExplicitSavedSelectionRestoresChosenVersionEvenIfOlder` |
| **Отказ при недоступной выбранной версии** | Запрос несуществующей версии выбрасывает `selectedVersionUnavailable` без скрытого fallback | `TranscriptVersionSelectionTests.testExplicitUnavailableSelectionThrowsErrorAndDoesNotSilentlyDefault` |
| **Отсутствие версий в legacy-записи возвращает nil (Core nil result)** | Записи без каталога транскриптов при отсутствии явного недоступного выбора возвращают `nil` при открытии сессии (поведение ядра, не UI-режим) | `TranscriptReviewSessionTests.testLegacyRecordingWithoutResultsReturnsNil` |

## 3. Ограничения и статус

- Задача 2.4 принята независимым ревью Sol (`W/2.4-final-review.md`).
- Задача 1.0 остаётся открытой `[ ]`.
- Реализация UI (секции 3 и 4 плана) не начата; документация явно разграничивает функционал ядра и будущий интерфейс.
