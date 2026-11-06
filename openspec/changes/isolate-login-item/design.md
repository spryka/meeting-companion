## Context

RecorderAppDelegate.applicationDidFinishLaunching автоматически настраивает SMAppService.mainApp при отсутствии loginItemConfigured; SettingsView отдельно вызывает register/unregister. Системный API действует от имени host процесса. Реальный helper Xcode находится в Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper; это executable, не Meeting Companion .app. Точная существующая системная запись не прочитана: sfltool отказал в авторизации.

## Goals / Non-Goals

Предотвратить побочные эффекты автозапуска от чужого host; сохранить поведение packaged public/local .app. Не менять общий lifecycle приложения, calendar/updater/capture и не удалять реальные login items.

## Decisions

Общий App-only AppLoginItem допускает работу только при bundleURL.pathExtension == app и bundleIdentifier == local.meeting-companion. Оба существующих mutation callers используют его. Проверка предшествует чтению status и preferences. Для неподдерживаемого host isEnabled=false, автоматическая настройка и setter ничего не делают, переключатель disabled.

SMAppService остаётся системной реализацией. Узкие closures status/register/unregister позволяют проверить реальные командные методы без вызовов ServiceManagement. Defaults передаётся из модели: production использует прежний standard, tests — isolated suite. configureIfNeeded сохраняет ключ, пропускает повторную настройку/уже enabled service и отмечает настройку только после успеха. Ошибка до marker оставляет возможность retry, отображение ошибки остаётся у caller. Явные enable/disable не меняют marker, как раньше.

Рассмотренные варианты: guard только в startup не защищает Settings setter; проверка имени swiftpm-testing-helper создаёт частное исключение и не защищает другие hosts; новый framework/protocol не нужен. Выбрана общая положительная проверка app identity.

## Risks / Trade-offs

Существующая системная запись автоматически не исчезает → не выдавать кодовый PASS за очистку macOS. Тесты используют только fake registrar; OS state не меняется. Local .app с тем же bundle ID допускается независимо от location, подписи и MCEnableUpdates.

## Migration Plan

Изменение без миграции. Доставляется следующей обычной версией отдельно; нынешние опубликованные assets не меняются.

## Open Questions

Нет продуктовых вопросов. Подтверждение и удаление существующей записи — отдельное действие владельца.
