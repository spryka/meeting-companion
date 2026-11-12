## 1. Контракт

- [x] 1.1 Проверить proposal/specs/design/ADR независимым reviewer и выполнить strict validation.

## 2. Реализация и интеграция

- [x] 2.1 Получить ожидаемый red для короткой речи/failure gate и подготовки без Silero; реализовать минимальный gate/caller и получить green.
- [x] 2.2 Обновить подпись модели Nemotron (отбор окон) и проверить её в progress snapshot; обновить README/pipeline docs, beta metadata и CHANGELOG; выполнить release/full tests/project checks и signed package.
- [x] 2.3 Сравнить packaged worker с research B на четырёх контрольных входах, проверить весь ordered journal и исходники; независимое итоговое ревью.

## 3. Установка

- [x] 3.1 Проверить idle/signature/data inventory, установить beta и проверить установленную version metadata/library/сохранность файлов.
- [x] 3.2 Проверить реальную запись с микрофоном и системным звуком, а также готовый транскрипт в установленной beta.41.

Версия beta.39 проверена по установленному Info.plist и exact InfoSHA пакета.
На четырёх контрольных записях packaged worker совпал с исследовательским
Nemotron gate; исходные WAV сохранились. Release build, полный suite,
project checks и независимое ревью прошли. Основные specs синхронизированы.
Ручная проверка реального микрофона, системного звука и готового транскрипта
завершена на beta.41 2026-11-12. Повторная выдача разрешений macOS не проверялась.
