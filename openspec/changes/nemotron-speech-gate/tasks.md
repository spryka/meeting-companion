## 1. Контракт

- [x] 1.1 Проверить proposal/specs/design/ADR независимым reviewer и выполнить strict validation.

## 2. Реализация и интеграция

- [x] 2.1 Получить ожидаемый red для короткой речи/failure gate и подготовки без Silero; реализовать минимальный gate/caller и получить green.
- [x] 2.2 Обновить подпись модели Nemotron (отбор окон) и проверить её в progress snapshot; обновить README/pipeline docs, beta metadata и CHANGELOG; выполнить release/full tests/project checks и signed package.
- [x] 2.3 Сравнить packaged worker с research B на четырёх контрольных входах, проверить весь ordered journal и исходники; независимое итоговое ревью.

## 3. Установка

- [x] 3.1 Проверить idle/signature/data inventory, установить beta и проверить установленную version metadata/library/сохранность файлов.
- [ ] 3.2 Физическая запись/микрофон/permissions UAT (отдельно, не считать выполненным по тестам).

Version проверена по установленному Info.plist и exact InfoSHA tested package; About UI не проверен из-за действий владельца. Физический UAT остаётся открытым; change не архивирован.

2026-11-11: владелец принял beta.39 и разрешил public beta.40; основные specs синхронизированы. Физический UAT по-прежнему не выполнен; активный change не архивируется.
