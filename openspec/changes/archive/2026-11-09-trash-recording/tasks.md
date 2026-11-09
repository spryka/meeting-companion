# trash-recording — завершённый план dev-loop

Цель: подтверждённо перемещать целую отдельную папку выбранной встречи в
системную Корзину, сохраняя ownership, modal, writer и late-callback guards.
Библиотека и close/hide основного окна блокируются до отмены или результата.

План утверждён владельцем сообщением «утверждаю план» 2026-11-09.
Change импортирован без перезаписи существующего; исходный master `32de9bb`,
итоговая база — принятый master `174beb1`. Работа выполнена в отдельном worktree;
чужие изменения сохранены. Интеграция параллельной задачи processing-progress-ui
не входила в этот change; её принятая реализация позже вошла в базовый master.

## Задачи

- [x] 1.1 Сверить proposal, T01–T05, design и ADR review; согласовать план.
- [x] 1.2 Прочитать связанные callers и пройти strict OpenSpec validation.
- [x] 2.1 Реализовать ownership/containment/identity validation и native Trash
  только для отдельной standard-папки; flat/shared/root/day/outside запрещены.
- [x] 2.2 Согласовать trash/capture/processing/rename/writer reservations,
  late writes/scan/cache и известный/неопределённый исход. TDD на synthetic folders.
- [x] 2.3 Реализовать выбранную строку/More, единое подтверждение и modal ownership,
  безопасный review/player teardown/reopen, selection/focus и input admission.
- [x] 3.1 Пройти полные автоматические проверки, release build и независимые ревью;
  обновить CHANGELOG, README и DESIGN.
- [x] 3.2 Проверить native сценарии на одноразовых папках и принять установленную
  локальную сборку владельцем; исключения явно зафиксированы ниже.
- [x] 3.3 Зафиксировать приёмку и закрыть SDD с синхронизацией основных specs.

## Принятые уточнения UI

- [x] E. Убрать context menu строки; добавить «В Корзину…» после Settings в More.
- [x] F. Корзинка только у выбранной кликом или стрелками записи; hover/Tab
  невыбранной строки не даёт право удаления. Delete/Backspace открывают
  подтверждение, Enter подтверждает, Escape отменяет. Поля/чужой modal/sheet,
  inactive/hidden window, auto-repeat, pending и устаревшие callbacks защищены.
- [x] F extra1. После удаления selection/current пусты, focus у соседа. Первая
  ↑/↓ или Space открывает именно сфокусированную строку и возвращает управление
  библиотеке. Проверены first/middle/last/single × обе стрелки и следующий Delete.
- [x] Локальная установка точного подписанного кандидата с прежней identity,
  process guards, source/stage/installed comparison и rollback bundle.
- [x] Owner UAT принята 2026-11-09: «шикарно. мержим сливаем, обновляем, SDD закрываем».

## Итоговая проверка

526 Swift Testing (7 vendor + 49 pipeline + 245 Core + 225 App) и 12 XCTest — PASS.
`swift test --no-parallel`, `swift build -c release`, `scripts/build-app.sh`,
`scripts/check-bundle.sh`, `openspec validate trash-recording --type change --strict`,
Python-free, module boundaries, finder self-test и `git diff --check` — PASS.
Native regression доставки стрелок после удаления прошла все 8 случаев.

Независимое ревью итоговой заморозки — PASS. Бюджеты сохранены:
A — 2 исходных ремонта, разбор подхода и 1 дополнительный; B — 1/2;
F — 2 исходных ремонта, разбор непокрытого row responder path и extra1/2.
Смена этапа/сессии счётчики не сбрасывала. Открытых материальных замечаний нет.

Owner UAT обнаружила пропуск стрелок на native row button. Исправление использует
его identity и прежний library handler, без новой focus-архитектуры. Проверки
admission (pending Enter, незавершённое открытие выбранной записи и modal refusal)
сохранены; ошибка реального чтения транскрипта не запрещает удаление.

Установлена beta.35/build71, executable SHA256
`4a507e35889f982f4da16258513104f6c223b661d808fbdd6d209bda59dfb0ec`.
Данные и настройки не менялись. Начало F — 22:06, установка финального исправления
— 23:31; точные интервалы ожидания и старт extra неизвестны. Подробные локальные
логи, RED/GREEN, manifests и patch freezes сохранены вне репозитория.

## Исключения и границы

Физическая проверка VoiceOver исключена владельцем и не объявляется пройденной.
Агент проверял удаление только на созданных тестовых папках; реальную чистку
библиотеки выполнял владелец. Native Trash/Finder restore проверены на одноразовой
папке. Нового root ADR, migration, permanent delete, собственного undo и очистки
Корзины нет. Дополнительных обязательных UAT гейтов не осталось.

Приёмка относится к реализации и установленной локальной сборке. Публичный выпуск
не входит в закрытие. [Итоговая приёмка](../../../../docs/trash-recording-acceptance.md).
