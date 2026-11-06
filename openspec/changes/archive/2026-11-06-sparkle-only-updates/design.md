## Context

AppUpdater проверяет Homebrew в start(), check() и validateCheckAdmission(homebrewManaged:). AppUpdatePolicy содержит только detector Caskroom; других пользователей кроме AppUpdater и отдельного self-check нет.

## Goals / Non-Goals

Единый существующий Sparkle route для update-enabled .app. Не менять MCEnableUpdates, каналы, подпись, busy/modal guards или installer. Не управлять Homebrew/tap и не останавливать запись ради проверки.

## Decisions

Удалить Homebrew ветки из AppUpdater; validateCheckAdmission() проверяет только существующий isCheckBusy/isBusy. Удалить ставшие ненужными detector и detector-only script. Существующие настройки/тесты admission переводятся на аргумент-free API. Beta opt-in и installPreparedUpdate()/deferred installation сохраняются.

TDD сначала показывает отказ текущего admission для свободной Homebrew-managed установки. После удаления installation-type входа тест проверяет разрешение свободной проверки и отказ при занятости, а существующие production Settings tests сохраняют более строгую политику установки/перезапуска. Реальные сеть/обновление установленного app не требуются для unit regression.

## Risks / Trade-offs

Старый установленный бинарник сохраняет старую политику до замены; изменение не может задним числом включить его updater. Публичный release и прежние подписи сохраняются, local builds по-прежнему могут иметь updates=false. История Homebrew receipts не является admission-состоянием приложения.

## Migration Plan

Никакой миграции данных или preferences. Изменение поставляется отдельной beta с новым build, не заменяя опубликованные beta.30 assets. Установка только при отсутствии активной работы и в ранее разрешённых границах; никакого force quit.

## Open Questions

Нет.
