## Why

Во время проверок macOS сообщила о добавлении swiftpm-testing-helper в объекты входа. Startup приложения вызывает SMAppService.mainApp.register без проверки host. Владелец согласовал узкое исправление, сохраняющее автозапуск настоящего приложения.

## What Changes

- Автоматическая регистрация и ручной переключатель допускаются только для Meeting Companion .app с прежним bundle ID.
- Тестовый/служебный host не читает ServiceManagement status, не регистрируется и не изменяет loginItemConfigured.
- Сохраняются однократная настройка, явное отключение, обработка ошибок и локальные сборки .app.

## Capabilities

### New Capabilities

Нет.

### Modified Capabilities

- `macos-status-menu`: ограничение операций автозапуска настоящим app bundle.

## Impact

RecorderAppDelegate, RecorderSettingsView, небольшой общий AppLoginItem и fake-only tests. Без новых зависимостей, изменения signing/bundle ID, разрешений, записей, календаря или обновлений. Удаление существующего системного login item и публикация beta не входят в согласованный план.
