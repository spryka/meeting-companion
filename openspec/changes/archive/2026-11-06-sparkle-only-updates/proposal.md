## Why

Приложение запрещает собственные обновления, если обнаруживает Homebrew receipt, и отправляет пользователя в терминал. Владелец явно потребовал убрать эту развилку: «давай историю с homebrew из приложения тоже уберем; sparkle решает этот вопрос».

## What Changes

- Все публичные update-enabled сборки используют существующий Sparkle flow независимо от способа установки.
- Удаляются проверка Caskroom, сообщение с brew-командами и лишний параметр admission.
- Сохраняются beta opt-in, отключение обновлений в локальных сборках и guards проверки/установки при работе и модальном вводе.

## Capabilities

### New Capabilities

Нет.

### Modified Capabilities

- `macos-status-menu`: единая проверка обновлений через Sparkle без отдельного Homebrew flow.

## Impact

AppUpdater, удаление AppUpdatePolicy и его отдельного detector self-check, SettingsPresentationTests, README/CHANGELOG. Без изменения recording/storage, Sparkle dependency, feed URL, ключей, подписей и application services. Homebrew остаётся возможным способом первоначальной установки; внешний tap не меняется.
