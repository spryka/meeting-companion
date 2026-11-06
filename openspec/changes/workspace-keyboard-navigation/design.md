## Context

Сейчас `AppMain` задаёт `⌘,`; формы имеют Enter/Escape. Ползунок аудио уже принимает обычные `←` / `→` при собственном фокусе. Библиотека — `ScrollView` с `LazyVStack` и карточками-кнопками, а не нативный `List` с keyboard selection. Транскрипт также использует `ScrollView`. Для оговорённых сочетаний и двух панелей требуется явное владение клавиатурой.

`RecorderViewModel.selectedHistoryURL`, `mainPage` и `workspaceShowsList` уже проходят `admitNavigation`; `WorkspaceLoadRequest` и manager защищают от поздних открытий. `TranscriptReviewWindowModel.togglePlayback/seekPlayback` сохраняют текущую playback identity и блокируют input. Их нужно переиспользовать.

Действуют ADR0001–0007 с частичными supersession: ADR0004 заменяет только user-visible history/selection clauses ADR0001/0003, ADR0005 — flat-retry clause ADR0004, ADR0007 — separate-Settings-window clause ADR0006. Неизменяемость recognition, edits/CAS и остальные части решений остаются в силе. Отчёт — [adr.md](adr.md).

## Goals / Non-Goals

**Goals:** все четыре выбранных сочетания, стрелки по активной панели, защита ввода/модальности и корректная навигация при асинхронной загрузке.

**Non-Goals:** глобальные сочетания, mute, экспорт по хоткею, переназначение, универсальный command framework, новые процессы/зависимости/permissions, управление записью напрямую клавишей `⌘N`, поиск внутри транскрипта и изменения storage/ASR.

## Decisions

### 1. Владение фокусом остаётся в App

Использовать обычный focus/responder механизм SwiftUI/AppKit в существующем workspace. Владельцами служат видимые библиотека, транскрипт, конкретный control или modal. Простого «последняя панель под мышью» недостаточно: оно ломает ввод и keyboard/VoiceOver navigation.

После выбора карточки фокус навигации остаётся в списке, поэтому серия стрелок листает записи, а пробел управляет плеером и не активирует карточку повторно. Tab/Shift-Tab сохраняют доступность самостоятельных кнопок и полей. При фокусе на обычной кнопке, popup или другом control её native key handling имеет приоритет; это не новый глобальный режим клавиатуры.

Начальный focus — библиотека; после modal dismissal возвращается существующий доступный control/панель того же workspace. Скрытая область при смене ширины не удерживает keyboard target. Пример узкого layout: `⌘F` показывает библиотеку; выбор стрелками не скрывает её, обычная активация карточки по-прежнему открывает detail.

Альтернативы: глобальный monitor не нужен для локальных сочетаний; app-wide перехват без проверки first responder поглощает пробелы/word navigation. Отдельный keyboard focus manager в Application переносит presentation state через принятую границу ADR0006.

### 2. Один dispatch на существующее действие

`⌘N` и `⌘F` предоставить через нативные команды/меню приложения, разрешаемые активным workspace. Существующий App delegate/host передаёт вызов туда, где живёт форма или поле поиска. Пробел, `←/→` и стрелки обрабатываются только в соответствующей поверхности навигации, после исключения владельцев ввода. Native menu equivalents обязаны соблюдать тот же приоритет: недостаточно назначить пробел всем окнам через безусловный `.keyboardShortcut`.

В реализации выбрать самый небольшой существующий responder/focus seam, позволяющий проверить реальный host. Служебный общий command bus, монитор всех окон и новые persistence keys не требуются. Если понадобится маленький App-local route/eligibility type для разных callers, он содержит только перечисленные команды и состояние их допуска, без второй navigation/playback state machine.

Действие повторно проверяет actual state и modal boundary при dispatch. Отказ не создаёт отложенную команду. `⌘N` открывает форму, а не вызывает capture intent; повторный вход сохраняет форму. Повторяемые `↑/↓` и seek допускаются, повтор keyDown пробела подавляется до отпускания.

### 3. Листаем существующую выдачу и current audio

Соседний entry вычисляется по той же flattened grouped выдаче, что реально отрисована. Изменяется существующий `selectedHistoryURL`; current открывается через прежний `WorkspaceLoadRequest`, без самостоятельного parallel open route. При пустой выдаче ничего не происходит, на краях нет wrap, отсутствующий selection начинает с первого entry. Выбранная карточка прокручивается в видимую часть списка, без анимации длительной обработки.

Пробел идёт в `togglePlayback`, обычные `←` / `→` без модификаторов — в `seekPlayback` после проверки текущей session/result и доступности transport; значение ограничено `[0, duration]`. Legacy TXT не получает audio fallback, модели не запускаются. Уже существующие стрелки ползунка остаются его собственным native-like control behavior: родительский обработчик не добавляет вторую перемотку к одному key event.

`↑/↓` в тексте меняют scroll position, а не audio position или выбранную реплику. Клавиатурный scroll явно проходит существующую границу ручного scroll/follow: одного изменения offset недостаточно, если оно не вызывает `onScrollPhaseChange`. Это проверяется outcome-тестом и реальным keyboard UAT.

### 4. Проверка через production callers и нативный host

TDD покрывает доступность/маршрутизацию, navigation outcomes и playback identity с синтетическим transport. Важны реальные host/responder/focus тесты: чистая функция выбора соседа не доказывает работу клавиатуры. Использовать существующие изолированные recorder defaults, временные recordings/appData и synthetic capture/transport; не писать в личную библиотеку или запускать модели.

Ручная проверка выполняется настоящими key events в нативном workspace: обе панели, список с фильтром, long transcript/follow, текстовый ввод и modal; затем wide/compact/narrow. Проверить русскую и латинскую раскладки для `⌘N`/`⌘F`, Menu accessibility и Tab/Shift-Tab/VoiceOver. Bitmap формы или прямой вызов model метода не является доказательством key routing.

## Risks / Trade-offs

- Перехват пробела активирует карточку и плеер дважды → один dispatcher с проверкой focused navigation target; outcome на physical key press и key repeat.
- После выбора записи focus уходит вправо → отдельно удерживать library navigation target, не менять его из async completion.
- Старое открытие A завершается после C → использовать прежний generation/session admission, проверять конечный current и отсутствие playback старой записи.
- Программный scroll не отключает follow → явно использовать имеющуюся ручную scroll boundary и проверить продолжающийся звук.
- Native toolbar/menu остаётся доступным под Settings → guards повторяются при dispatch, даже при устаревшем enabled-state.
- Narrow layout прячет библиотеку после первой стрелки → keyboard selection не меняет list/detail presentation; явная активация карточки сохраняет прежний путь.

## Migration Plan

Изменения ограничены App и tests; storage, result/edit schema, defaults, recordings и signing identity не меняются. После согласования документов — TDD, scoped implementation и review, затем обязательные проверки проекта и keyboard UAT. Записать пользовательское изменение под `[Unreleased]`. Установка/новая beta — отдельный шаг после проверки, без замены поверх активной работы.

Откат состоит в возврате App-команд/фокуса прежней версии; пользовательские данные не мигрируются и не требуют восстановления.

## Open Questions

Блокирующих продуктовых вопросов нет; набор клавиш и панели выбраны пользователем. Документы ожидают согласования перед реализацией по CONTRIBUTING.md. Новый root ADR не требуется: это локальная маршрутизация presentation в уже принятой App ownership boundary, а не изменение архитектуры.
