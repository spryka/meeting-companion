## MODIFIED Requirements

### Requirement: P03 Detailed recording screen

Экран записи SHALL показывать полный маршрут, текущую модель/дорожку, один достоверный локальный прогресс и предупреждения по [design.md](../../../2026-11-09-processing-progress-ui/design.md), используя тот же job snapshot, что капсула.

#### Scenario: Details and late completion
- **WHEN** идёт распознавание системного звука, затем сборка/публикация результата
- **THEN** видны модель, дорожка 2 из 2 и реальные окна/процент; «Сохранение» остаётся текущим до принятого успешного завершения; ошибка не выдаётся за готовый результат

#### Scenario: Nemotron gate model label
- **WHEN** отображается этап отбора окон vad
- **THEN** подробности показывают модель «Nemotron (отбор окон)»
- **AND** station IDs, маршрут, количество этапов и wire protocol сохраняются
