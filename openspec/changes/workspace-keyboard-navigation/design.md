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

Native sheet restoration может оставить firstResponder самим NSWindow. Общий recovery при becomeKey и после didEndSheet повторно проверяет admission и сохраняет полезный native responder; только при его отсутствии возвращает доступную navigation surface. Это lifecycle-проверка, а не отдельный обработчик Esc. Отложенный callback не активирует скрытое/неактивное окно и не перехватывает ввод новой модалки.

Альтернативы: глобальный monitor не нужен для локальных сочетаний; app-wide перехват без проверки first responder поглощает пробелы/word navigation. Отдельный keyboard focus manager в Application переносит presentation state через принятую границу ADR0006.

### 2. Один dispatch на существующее действие

`⌘N` и `⌘F` предоставить через нативные команды/меню приложения, разрешаемые активным workspace. Существующий App delegate/host передаёт вызов туда, где живёт форма или поле поиска. Пробел, `←/→` и стрелки обрабатываются только в соответствующей поверхности навигации, после исключения владельцев ввода. Native menu equivalents обязаны соблюдать тот же приоритет: недостаточно назначить пробел всем окнам через безусловный `.keyboardShortcut`.

В реализации выбрать самый небольшой существующий responder/focus seam, позволяющий проверить реальный host. Служебный общий command bus, монитор всех окон и новые persistence keys не требуются. Если понадобится маленький App-local route/eligibility type для разных callers, он содержит только перечисленные команды и состояние их допуска, без второй navigation/playback state machine.

Действие повторно проверяет actual state и modal boundary при dispatch. Отказ не создаёт отложенную команду. `⌘N` открывает форму, а не вызывает capture intent; повторный вход сохраняет форму. Повторяемые `↑/↓` и seek допускаются, повтор keyDown пробела подавляется до отпускания.

Eligibility getters для render/menu validation только читают состояние (`!workspace.hasInput`); mutating admission и публикация причины отказа принадлежат исполнению команды. Вызов `admitNavigation()` из `canStartRecording` создавал render/publication feedback при Settings поверх формы с открытым current; этот pre-existing дефект устраняется на общей границе getter, без обходов в отдельных views.

### 3. Листаем существующую выдачу и current audio

Соседний entry вычисляется по той же flattened grouped выдаче, что реально отрисована. Изменяется существующий `selectedHistoryURL`; current открывается через прежний `WorkspaceLoadRequest`, без самостоятельного parallel open route. При пустой выдаче ничего не происходит, на краях нет wrap, отсутствующий selection начинает с первого entry. Выбранная карточка прокручивается в видимую часть списка, без анимации длительной обработки.

Пробел идёт в `togglePlayback`, обычные `←` / `→` без модификаторов — в `seekPlayback` после проверки текущей session/result и доступности transport; значение ограничено `[0, duration]`. Legacy TXT не получает audio fallback, модели не запускаются. Уже существующие стрелки ползунка остаются его собственным native-like control behavior: родительский обработчик не добавляет вторую перемотку к одному key event.

После двух R2 ремонтов владелец разрешил минимальный Core scope: play intent и общий `toggle()` принадлежат существующему `TranscriptPlaybackController`, который получает точные `ended`/`failed`. Intent сохраняется при buffering/waiting и seek через конец, очищается при явной паузе, новом select, close, failure или настоящем ended. App использует этот route, без собственной playback state machine и эвристики ended по позиции. Наблюдаемые ready/playing states и transport protocol не меняются.

Уточнение после UAT beta.27 утверждено владельцем: `↑/↓` в структурированном тексте переходят по существующему `model.rows` и вызывают тот же `seekPlayback(to: row.start)`, что кнопка таймкода. Скорость и play/pause сохраняются, выбранная реплика раскрывается в viewport. Короткий transient cursor различает соседние реплики с одинаковым таймкодом и накапливает быстрые нажатия до completion; это не сохранённый выбор или второй playback controller. Внешняя перемотка/движение audio, новый result/session и close не оставляют stale cursor. Отложенная команда повторно проверяет актуальные focus/modal/session/result guards. Аудио недоступно — раскрывается только реплика; legacy TXT сохраняет прежнюю pixel-прокрутку с ручной scroll/follow boundary. Прокрутка мышью по-прежнему приостанавливает follow, навигационный переход по реплике сам по себе этого не делает.

### 4. Проверка через production callers и нативный host

R5: turn/relative/waveform seek регистрируют общий App request синхронно, до Task. Новое действие заменяет queued request, relative target накапливается от последнего запрошенного положения. Core продолжает владеть самим transport и защитой completion; второго playback controller нет. Вход в Settings, форму, editor или native sheet инвалидирует ещё не исполненный request на существующей границе ввода. Уже начатый transport seek не откатывается при открытии Settings. Ручной scroll и явный возврат к follow освобождают transient turn cursor, чтобы не блокировать прежний reveal route.

TDD покрывает доступность/маршрутизацию, navigation outcomes и playback identity с синтетическим transport. Важны реальные host/responder/focus тесты: чистая функция выбора соседа не доказывает работу клавиатуры. Использовать существующие изолированные recorder defaults, временные recordings/appData и synthetic capture/transport; не писать в личную библиотеку или запускать модели.

Ручная проверка выполняется настоящими key events в нативном workspace: обе панели, список с фильтром, long transcript/follow, текстовый ввод и modal; затем wide/compact/narrow. Проверить русскую и латинскую раскладки для `⌘N`/`⌘F`, Menu accessibility и Tab/Shift-Tab/VoiceOver. Bitmap формы или прямой вызов model метода не является доказательством key routing.

### 5. Дополнение Esc — план утверждён владельцем

Переиспользовать локальные cancel routes: `RecorderViewModel.dismissSettings`, отмену формы записи, rename sheet и `cancelTextDraft`/`cancelDraft`. Формы уже используют `.keyboardShortcut(.cancelAction)`, Settings — `.onKeyPress(.escape)`; сначала проверить реальные native responders, исправлять только подтверждённые пробелы. Не вводить глобальный обработчик Esc, второй modal manager или новую политику черновиков.

Верхний native popup/menu/IME обрабатывает отмену раньше нижней формы; одно нажатие не должно закрыть два слоя. Attached sheet и modal window сохраняют ownership. Проверить Settings с фокусом в поле и после dismiss, формы с вводом, редактор с draft, nested native popup и отсутствие modal. Outcome — закрытый ожидаемый слой, доступный firstResponder и неизменённые сохранённые данные/фоновые операции. Область проверки включает `SettingsView`, `RecorderView`, `RecordingHistoryView`, `TranscriptReviewWindow`, существующие workspace responders/callers, App host tests и CHANGELOG; новые fixtures/config/dependencies не требуются.

## Risks / Trade-offs

- Перехват пробела активирует карточку и плеер дважды → один dispatcher с проверкой focused navigation target; outcome на physical key press и key repeat.
- После выбора записи focus уходит вправо → отдельно удерживать library navigation target, не менять его из async completion.
- Старое открытие A завершается после C → использовать прежний generation/session admission, проверять конечный current и отсутствие playback старой записи.
- Программный scroll не отключает follow → явно использовать имеющуюся ручную scroll boundary и проверить продолжающийся звук.
- Native toolbar/menu остаётся доступным под Settings → guards повторяются при dispatch, даже при устаревшем enabled-state.
- Narrow layout прячет библиотеку после первой стрелки → keyboard selection не меняет list/detail presentation; явная активация карточки сохраняет прежний путь.

## Migration Plan

Изменения ограничены App, существующим Core playback controller и tests; storage, result/edit schema, defaults, recordings и signing identity не меняются. После согласования документов — TDD, scoped implementation и review, затем обязательные проверки проекта и keyboard UAT. Записать пользовательское изменение под `[Unreleased]`. Установка/новая beta — отдельный шаг после проверки, без замены поверх активной работы.

Откат состоит в возврате App-команд/фокуса прежней версии; пользовательские данные не мигрируются и не требуют восстановления.

## Open Questions

Блокирующих продуктовых вопросов нет; набор клавиш и панели выбраны пользователем. Документы ожидают согласования перед реализацией по CONTRIBUTING.md. Новый root ADR не требуется: это локальная маршрутизация presentation в уже принятой App ownership boundary, а не изменение архитектуры.
