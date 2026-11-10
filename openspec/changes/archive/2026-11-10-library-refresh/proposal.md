# Обновление библиотеки

## Why

В широком workspace «+» в библиотеке дублирует заметную «Новую запись». При возврате папки из Корзины пользователю нужна явная команда повторного чтения библиотеки без перезапуска приложения.

## What Changes

- Заменить sidebar «+» кнопкой «Обновить библиотеку»; добавить ⌘R и одноимённый пункт нативного меню.
- Оставить «Новую запись» в основной панели; только в узком списке показать локальную кнопку, когда панель документа скрыта.
- Переиспользовать существующий scan/merge; добавить единые guards, состояния ожидания/ошибки и сохранение открытого workspace.

## Capabilities

### New Capabilities

- `library-refresh`: явное обновление, восстановленные записи, command admission и состояния UI.

### Modified Capabilities

- `desktop-workspace`: W01 — заменить обязательный sidebar «+», сохранить остальные сценарии целиком.

## Impact

App: `RecordingHistoryView.swift`, `WorkspaceKeyboard.swift`, `AppMain.swift`, `RecordingHistory.swift`, при необходимости существующий набор icons. Application: существующий `RecordingHistoryRepository.refresh(root:)`, без второго индекса. Тесты history, keyboard/admission и workspace UI; `CHANGELOG.md`.

Без изменений storage/schema, capture, pipeline, корзины и capsule. Новых зависимостей нет.
