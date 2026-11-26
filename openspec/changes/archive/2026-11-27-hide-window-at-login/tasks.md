**Цель.** После входа в macOS доступен значок, а главное окно остаётся скрытым. Открытие из Finder и «Библиотека» показывают окно.

**Границы.** Один этап с независимым ревью `gpt-6.1-sol high`. Сборка и тесты в текущем checkout. Установка и проверка реального входа отдельно.

**Согласование `$dev-loop`.** Пользователь подтвердил план 2026-11-21 в @thread:thr_cxy937tt6s#msg=465.

**База.** `7a83dd97b680721f9e3bc5120312f62a506f34be`. До подготовки теста три затронутых Swift-файла были чистыми. В рабочем дереве есть отдельные untracked-файлы `local-voice-identity`, эксперименты и `.playwright-mcp/`.

## 1. Показ окна при запуске

- [x] 1.1 Воспроизвести безусловный показ окна тестом для запуска при входе.
- [x] 1.2 Применить условие показа окна в `RecorderAppDelegate` и обновить changelog.
- [x] 1.3 Проверить `AppLoginItemTests`, release-сборку, границы модулей, recording finder и `openspec validate hide-window-at-login --strict`.
- [x] 1.4 Передать итоговый diff на независимое read-only ревью и разобрать замечания.
- [x] 1.5 Подтвердить полный `swift test` в сессии с рабочим SwiftPM runner и доступом к Metal.

## 2. Ручная проверка

- [x] 2.1 С установленной сборкой войти в macOS при включённом автозапуске. Проверить скрытое главное окно, значок, доступность напоминаний и открытие «Библиотеки». Выйти из приложения и открыть его через Finder.

## Текущее состояние

- Владелец отдельно проверил автозапуск и согласовал merge в `master`.
- 2026-11-21, MSK. Подготовка началась до 12:56, первая проверенная правка к 13:04, release-сборка завершилась в 13:10:49.
- RED подтверждён нативным `login-launch-harness.swift` из хранилища треда, скомпилированным Xcode `swiftc` вместе с `AppLoginItem.swift` до исправления. Exit 1, два ожидаемых падения для автозапуска. После правки все четыре сценария прошли.
- `AppLoginItemTests` прошёл на собранном test bundle через `swiftpm-testing-helper` из Xcode, 8 тестов. `login-launch-focused.log`.
- `swift build -c release --disable-sandbox` прошёл внутри рабочей песочницы с установленным Metal Toolchain. `login-launch-release-build.log`. Проверка границ модулей прошла с тем же флагом только для вложенного `swift package`, `login-launch-boundaries.log`. Recording finder self-test, OpenSpec strict и `git diff --check` прошли.
- Полный `swift test` собрал тесты, но раннер не выдал итог и был остановлен. Прямой прогон выявил ограничения сессии `sandbox_apply: Operation not permitted` и `No Metal device available`, а также отказ `afconvert` с `Invalid format string: aac`. Автопроверка разрешений завершилась по тайм-ауту для запуска вне рабочей песочницы. Логи `login-launch-full-test.log`, `login-launch-core-with-cache.log`, `login-launch-xctest.log`.
- Ревью @thread:thr_xrnfgpuex8 (`gpt-6.1-sol high`), PASS без замечаний, ремонты 0/2. SHA-256 `login-launch-review.diff` равен `ab36e3cd58d2f43f78702a3ff0362d45a07878dfcc0122981b54a8099b47e07d`. Хеши проверены до добавления этого отчёта в план.
- Установленная версия и реальный вход в macOS ожидают отдельной проверки.

- 2026-11-27. Владелец подтвердил проверку автозапуска и обычного открытия. Полный последовательный swift test с Xcode и Metal прошёл на master 40f999f, 764 теста.
