## ADDED Requirements

### Requirement: M05 Login item belongs to the application

Автозапуск SHALL настраиваться только из Meeting Companion .app с bundle ID local.meeting-companion. Автоматическая первичная настройка и переключатель в Основных SHALL использовать один admission. Тестовые и другие hosts SHALL не обращаться к ServiceManagement status/register/unregister и не изменять loginItemConfigured.

#### Scenario: M05.1 Unsupported host

- **GIVEN** executable/тестовый bundle либо .app с другим или отсутствующим bundle ID
- **WHEN** выполняется первичная настройка или команда enable/disable
- **THEN** системная служба не читается и не изменяется, loginItemConfigured сохраняется; переключатель недоступен и не показывает enabled

#### Scenario: M05.2 First real application launch

- **GIVEN** настоящий public/local Meeting Companion .app и loginItemConfigured отсутствует
- **WHEN** выполняется первичная настройка
- **THEN** disabled service регистрируется один раз; уже enabled service повторно не регистрируется; marker записывается после успешной настройки

#### Scenario: M05.3 Explicit preference survives relaunch

- **GIVEN** настоящий .app с завершённой первичной настройкой
- **WHEN** пользователь отключает автозапуск и приложение запускается снова
- **THEN** выполняется unregister, последующий startup не включает его заново; ручное включение остаётся доступным

#### Scenario: M05.4 Service failure remains actionable

- **GIVEN** настоящий .app и системная операция завершается ошибкой
- **WHEN** выполняется первичная настройка либо ручной переключатель
- **THEN** caller получает исходную ошибку для существующего сообщения; неуспешная первичная настройка не записывает marker и может быть повторена
