# Swift-чтение: блок 1.3

Дата: 2026-10-30. Реализован read-only reader; подключение к истории и UI
не входит в этот блок.

## Изменения

- `Sources/MeetingCompanionCore/TranscriptDocument.swift`: типизированный JSON v1,
  `load(from:recordingDirectory:)`, понятные ошибки `LocalizedError`.
- `Tests/MeetingCompanionCoreTests/TranscriptDocumentTests.swift`: 16 тестов,
  включая шесть общих valid и пять invalid fixtures.
- `Package.swift`: только testTarget с зависимостью от существующего core.

Проверяются обязательные поля, включая присутствие nullable context,
detectedVoiceCount, mixPath и warning.sourceID; неизвестные поля v1 игнорируются.
ID уникальны в своих пространствах, speaker ID непрозрачны; baseline и final
могут иметь совпадающие ID. Проверяются ссылки, владение словами, интервалы,
нумерация голосов, различие нуля и неизвестного числа голосов, состояния AEC
и playback. При disabled/failed коррекции baseline и final должны совпадать
по тексту и интервалам в пределах источника, без требования совпадения ID/голоса.

Аудиопути проверяются по компонентам с разрешением symlink, включая отсутствующий
конечный файл. Выход из папки и ссылки на микс другой версии отклоняются.
Applied AEC требует отдельную копию микрофона своей версии. resultID допускает
произвольное имя одного каталога, но не traversal. Наличие аудио не требуется:
документ с отсутствующим миксом остаётся читаемым. Reader не пишет файлы.

## RED и независимая проверка

Исполнитель — codex-lb/gpt-6.1-sol#medium. Ведущий прочитал diff и самостоятельно
повторил RED на сохранённом компилируемом skeleton во временном Swift package
с копиями тех же тестов и fixtures, без отката рабочего дерева.
Сборка успешна; 13 тестов упали с 178 issues на notImplemented и неправильной
категории ошибки. Это проверка поведения, не ошибка импорта/окружения.

Ревью выявило два пропуска: принадлежность микса своей версии и совпадение
baseline при выключенной/неуспешной коррекции. Исполнитель добавил регрессии:
до исправления 16 тестов дали 15 issues `Expected an error` в трёх новых тестах.
После исправления ведущий повторил GREEN: 16/16.

## Команды и результаты

```sh
rtk proxy swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib --filter TranscriptDocumentTests
rtk proxy swift build -c release
rtk proxy uv run --quiet --python 3.12 --with numpy --with soundfile python -B -m unittest discover -s transcription -p 'test_*.py' -q
rtk proxy openspec validate transcript-editor --strict
rtk git diff --check
```

- Swift: 16/16 passed, без expectedFailure/xfail.
- Release-сборка успешна; прежние linker warnings о путях CLT остаются.
- Python: 107 тестов, 106 passed, 1 skipped (native AEC binary не задан).
- OpenSpec strict и whitespace check успешны.

Ведущий дополнительно создал во временном каталоге семь синтетических записей
через реальный `transcript_document.publish_result`, затем скомпилировал небольшой
Swift harness с production reader. Все семь result.json открылись с сохранением
слов и baseline: AEC disabled/applied/bypassed/failed, успешная коррекция,
частичный сбой коррекции, отказ микса с playback.unavailable. Для успешного микса
использован реальный afconvert; отказ внедрён отдельно. Временные harness и записи
не входят в репозиторий. Это дополнительная проверка, не постоянный cross-language
интеграционный тест CI.

## Ограничения

- В установленном CLT нет XCTest; тесты используют штатный Swift Testing.
  Для воспроизводимого запуска потребовался явный plugin-флаг выше; окружение
  не изменялось, абсолютный путь не добавлен в Package.swift.
- Reader проверяет пути в момент загрузки; это не защита от последующей внешней
  подмены symlink. Безопасное открытие файлов плеером ещё предстоит реализовать.
- UI, история версий, сохранение edits, воспроизведение и UAT не реализованы
  этим блоком. Отсутствующее аудио проверено только на границе reader.
- Полный прогон выполнен на текущем dirty дереве; посторонние изменения сохранены.
- Bundle не собирался/не устанавливался; commit/push/publication не выполнялись.

Закрыта только 1.3. Задачи 1.0, 1.4 и последующие остаются открытыми.
