# Meeting Companion

Записывает микрофон и системный звук, после остановки создаёт текст встречи
с временными метками и разделением голосов. Apple Silicon, macOS 15+.
Распознавание речи — русский язык.

## Первый запуск

1. Перенеси `Meeting Companion.app` в «Программы» и открой его.
2. Разреши доступ к микрофону и записи системного звука в macOS.
3. Если модели ещё не установлены, нажми «Скачать модели». Интернет нужен
   только для первоначальной подготовки; затем транскрибация работает офлайн.
4. Выбери микрофон и нажми «Записать». После «Стоп» дождись готового текста
   и нажми «Открыть текст».

Python, пакеты и модели устанавливаются приложением автоматически при подготовке.
Они хранятся отдельно в `~/Library/Application Support/MeetingCompanion/`;
кэши Ollama и других приложений не используются.
Записи никуда не отправляются. При сбое звук сохраняется; кнопку «Получить текст»
можно использовать для повторной транскрибации последней записи.

## Записи

По умолчанию — `~/Downloads/Meetings/YYYY-MM/DD/`, по времени этого Mac.
Папка меняется в «Настройки…», кнопка «Записи» открывает её в Finder.

Для каждой встречи сохраняются:

- `meeting_YYYY-MM-DD_HH-mm-ss.m4a` — общая резервная запись;
- `*.host_record.wav` — микрофон;
- `*.remote_record.wav` — системный звук;
- `*.sources.transcript.txt` — готовый текст;
- `*.context.json` — выбранная встреча из календаря, если есть.

Дорожки WAV синхронизированы, включая тишину, и готовы для моделей:
16 kHz mono PCM16. Транскрибация читает их напрямую; ffmpeg не используется. Наушники уменьшают попадание голоса собеседника в микрофон.
BlackHole не нужен. Отдельные транскрипты дорожек и журналы ошибок лежат рядом.
Общий текст собирается по временным меткам слов: реплика другого канала
разрывает абзац, непрерывная речь делится на участки до 15 секунд.
При одновременной речи сохраняются обе реплики; метки времени приблизительные.
После успешной транскрибации появляется уведомление macOS с названием встречи
из сохранённого контекста или именем записи. Уведомление не требует ответа;
macOS один раз запрашивает разрешение на показ баннеров.

## Календарь и фоновая работа

Приложение остаётся в строке меню при закрытии окна. Нажатие на значок открывает
окно; правое нажатие — настройки, автозапуск и выход.

Доступ к календарю необязателен. При начале встречи появляется напоминание
«На встрече? Начать запись?». «Да, начать» запускает запись, «Нет» закрывает
напоминание. Встречу можно выбрать вручную. Приложение не подключается к звонку
и не меняет события календаря.

## Диагностика

«Настройки…» показывает разрешения macOS. «Проверить всё» проверяет папку
и короткое распознавание локальными моделями. Уровни звука видны в главном окне.
Статусы разрешений обновляются автоматически: зелёный — доступ есть, оранжевый —
ещё не запрошен, красный — доступа нет. Во время подготовки видны таймер и живой
лог скачивания Python, пакетов и моделей, объём файлов на диске и время
последнего изменения. Объём на диске включает распакованные пакеты и не является
процентом загрузки. На медленном соединении подготовка может
занять больше нескольких минут. Если доступ запрещён, открой «Разрешения macOS»
и разреши его вручную.

## Сборка из исходников

Нужны macOS 15+, Apple Silicon, Swift 6 (Xcode Command Line Tools) и
[uv](https://docs.astral.sh/uv/getting-started/installation/) в PATH.
Homebrew в примере — один из способов установить uv; получателю готового
приложения он не нужен.

```bash
xcode-select --install  # если инструменты разработчика ещё не установлены
brew install uv
./scripts/build-app.sh
./scripts/install-app.sh
```

Сборка создаёт `dist/Meeting Companion.app` из исходников и `Resources/Info.plist`.
По умолчанию используется подпись ad-hoc. Для подписи своим сертификатом:

```bash
CODESIGN_IDENTITY="имя сертификата в Keychain" ./scripts/install-app.sh
```

Установка требует закрыть приложение и отказывается заменять установленную
подписанную версию сборкой ad-hoc: смена подписи может сбросить разрешения macOS.


Встроенный конвейер находится в `transcription/`: GigaAM для речи и Nemotron
для голосов. CLI использует ресурсы установленного приложения:

```bash
swift run -c release meeting-companion --help
```

## Проверки

Проверки без XCTest:

```bash
uv run --quiet --python 3.12 --with numpy --with soundfile python -B -m unittest discover -s transcription -p 'test_*.py' -q
./scripts/check-bundle.sh "dist/Meeting Companion.app"
swiftc Sources/MeetingCompanionCore/RecorderCore.swift Sources/MeetingCompanionCore/SourceAudioFiles.swift scripts/check-source-audio.swift -o /tmp/check-source-audio
/tmp/check-source-audio
swiftc Sources/MeetingCompanionCore/Transcription.swift scripts/check-transcription.swift -o /tmp/check-transcription
/tmp/check-transcription
swiftc Sources/MeetingCompanionApp/MeetingCalendar.swift scripts/check-meeting-context.swift -o /tmp/check-meeting-context
/tmp/check-meeting-context
swiftc Sources/MeetingCompanionApp/RecorderDiagnostics.swift scripts/check-diagnostics.swift -o /tmp/check-diagnostics
/tmp/check-diagnostics
swiftc Sources/MeetingCompanionApp/TranscriptionNotifications.swift scripts/check-transcription-notifications.swift -o /tmp/check-transcription-notifications
/tmp/check-transcription-notifications
```

## Распространение

Архив из `dist/` содержит приложение с конвейером и uv. Записи и модели
в архив не входят; модели устанавливаются на Mac получателя.
Для архива приложения:

```bash
ditto -c -k --sequesterRsrc --keepParent "dist/Meeting Companion.app" "dist/Meeting Companion-0.1.0-arm64.zip"
```

Локальная подпись/ad-hoc не заменяет Developer ID и Apple notarization.
При скачивании такого архива macOS может потребовать разрешить запуск через
«Системные настройки → Конфиденциальность и безопасность». Не отключай Gatekeeper.

Исходники экспортируются без `.build/`, `dist/`, `.codesign/`, записей и кэшей.
Сторонние компоненты и модели: [THIRD_PARTY.md](THIRD_PARTY.md).
