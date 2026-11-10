# Дизайн Meeting Companion

Практическая карта текущего macOS-интерфейса. Канонический источник — Swift-код:
таблицы ниже помогают выбрать существующую роль, а не создают второй набор токенов.
HTML-референс и активные предложения объясняют замысел; при расхождении фактическое
поведение нужно смотреть в production caller. Состояние проверки описано отдельно
в [verification-release](openspec/changes/archive/2026-11-06-refresh-macos-interface/verification-release.md).
Последующие изменения обработки и аудио приняты в [beta.35](docs/beta35-acceptance.md);
дизайн капсулы описан в [processing-progress-ui](openspec/changes/archive/2026-11-09-processing-progress-ui/design.md).

## Где менять

| Область | Владелец |
|---|---|
| Цвета, spacing, общие кнопки/поля/dialog, векторные иконки | [InterfaceStyle.swift](Sources/MeetingCompanionApp/InterfaceStyle.swift): `InterfaceStyle`, `ODButtonStyle`, `odInput`, `ODDialog`, `ODIconView` |
| Главное окно, native header, separator, min-size | [RecordingWindowState.swift](Sources/MeetingCompanionApp/RecordingWindowState.swift): `AppWindowState.updateHeader`, `WorkspaceHeaderHostingView` |
| Библиотека, поиск, footer, toolbar/More | [RecordingHistoryView.swift](Sources/MeetingCompanionApp/RecordingHistoryView.swift): `RecordingHistoryView`, `RecorderWorkspaceView` |
| Подтверждение переноса в Корзину | [RecordingTrashView.swift](Sources/MeetingCompanionApp/RecordingTrashView.swift): `RecordingTrashOverlay`; admission и outcome — `RecorderViewModel` |
| Документ, реплики, player, редактирование | [TranscriptReviewWindow.swift](Sources/MeetingCompanionApp/TranscriptReviewWindow.swift): `TranscriptReviewWindowView`, `WaveformScrubberView` |
| Новая запись, meeting/mic fields, уровни | [RecorderView.swift](Sources/MeetingCompanionApp/RecorderView.swift): `FullRecorderView`, `MeetingPicker`, `FormLevelMetersView` |
| Settings modal, навигация и настройки | [SettingsView.swift](Sources/MeetingCompanionApp/SettingsView.swift): `WorkspaceSettingsOverlay`, `SettingsShell`, `RecorderSettingsView`, локальные `ODSettings*` |
| Независимая капсула | [RecordingCapsuleController.swift](Sources/MeetingCompanionApp/RecordingCapsuleController.swift): panel/position; [RecordingCapsuleView.swift](Sources/MeetingCompanionApp/RecordingCapsuleView.swift): содержимое |
| Status menu и календарное напоминание | [StatusMenu.swift](Sources/MeetingCompanionApp/StatusMenu.swift): `StatusMenu.build`; [RecorderAppDelegate.swift](Sources/MeetingCompanionApp/RecorderAppDelegate.swift): status item, `MeetingReminderView` |

`ODColors` и `ODSpacing` — aliases `InterfaceStyle`. Отдельного `ODLayout` сейчас
нет: layout constants объявлены в `InterfaceStyle`, часть фактических размеров и
порогов повторена в screen views. При локальной правке сначала проверить оба caller,
не проводить попутную нормализацию. Общая роль меняется в helper; исключение одного
экрана — у его владельца.

## Шрифт и текстовые роли

Основной API — SwiftUI `Font.system(size:weight:)`; без указанного weight используется
обычный системный вес. Имя семейства не зафиксировано, свой font-файл не задаётся
этими компонентами. `.headline`, `.callout`, `.caption` — semantic system fonts:
их pt и метрики здесь не подменяются константами. `monospacedDigit()` выравнивает
цифры, а не переводит весь текст на моноширинный шрифт.

В столбце «line box» указан аргумент `odLineBox(size:height:)`, если он есть.
Helper считает положительный leading из метрик `NSFont.systemFont(ofSize:)`,
добавляет `lineSpacing` и половину leading сверху/снизу; это целевой line box,
не измеренная фиксированная высота каждой строки. «Intrinsic» означает, что
явная высота строки не задана.

| Роль / место | System size, pt / weight | Line box, pt / особенности |
|---|---|---|
| `WorkspaceBrand` | narrow 16, compact 13, wide 14 / semibold | 20 / 16.25 / 17.5; tracking −0.3; narrow одна строка имени, остальные две |
| Заголовок библиотеки «Записи» | narrow 28, остальные 22 / semibold | Intrinsic |
| Группа дат / карточка: название / metadata | 12 semibold / 15 semibold / 12 regular | 18.6 / 21 / 15.6; название максимум 2 строки, status 1 |
| Поиск библиотеки | 14 regular | 21.7 |
| Название документа | `min(32, max(24, workspaceWidth * 0.025))` / semibold | size × 1.25; tracking −0.8; текст selectable |
| Метка готовности / metadata документа | 12 semibold / 13 regular | 18.6 / 20.15 |
| Заголовок «Транскрипт» / пояснение | 14 semibold / 13 regular | 18.9 / 20.15 |
| Текст реплики / имя | 16 regular / 13 semibold | 28 / 16.9; реплика переносится, selectable |
| Таймкод реплики | 12 regular, monospaced digits | 15.6; колонка narrow 44, остальные 48 |
| Legacy TXT | 16 regular | Native metrics + `lineSpacing(6)`, не line-height 22 |
| Toolbar label / новая запись | 13 medium / narrow 13, остальные 14 medium | Intrinsic |
| Player время / follow и message | narrow 11, остальные 12 / narrow 10, остальные 11 | Intrinsic; время monospaced digits, message максимум 2 строки |
| `ODButtonStyle` | обычный 14, compact 12 / medium | 18.2 / 15.6 |
| `odInput` / `ODField` label / `ODDialog` title | 15 regular / 13 semibold / 22 semibold | Intrinsic |
| Settings title / подзаголовок приложения | 22 semibold / 12 regular | 29.7 / 18.6 |
| Settings page title / introduction | 20 semibold / 13 regular | 31 / 20.8 |
| Settings group / row label / hint | 12 semibold / 14 medium / 12 regular | 18.6 / 21.7 / 19.2 |
| Settings tiles / selector / footer | 12 medium / 13 regular / 11 regular | Intrinsic; footer может переноситься |
| Capsule timer / title / subtitle | 20 medium / 13 semibold / 11 regular | Intrinsic; timer tracking −0.7 и monospaced digits; title/subtitle 1 строка с tail ellipsis |
| Capsule обработки: «Подробнее» / «Открыть» | 13 regular | Native borderless button, без ручного close |
| Capsule записи/ошибки: close / overtime | 12 medium / 11 medium | Intrinsic; отдельные состояния от обработки |
| Новая запись: intro / диагностика | 14 regular / `.headline`, `.callout`, `.caption` | Native intrinsic; diagnostic report `.system(.caption, design: .monospaced)` |
| Reminder title / пояснение / Picker и кнопки | `.headline` / `.caption` / native inherited | Native intrinsic; пояснение переносится |
| Status menu | Системная `NSMenu` typography | Native intrinsic; размер не задаёт OD style |

Длинный документ переносит текст; не обрезать его ради выравнивания с карточкой.
В капсуле полный title/progress/error доступен через `.help` там, где он задан.
Не переносить её single-line ellipsis на редактор. В диалоге текста `TextEditor`
имеет 16 pt и высоту 192; preview назначения имени — 14 pt / line box 22.4.

## Семантические цвета

Ниже точные sRGB значения dynamic `NSColor` из `InterfaceStyle`, не выборка пикселей
снимка. Светлая/тёмная ветка определяется `bestMatch([.darkAqua, .aqua])`.
`AppAppearance` поддерживает system/light/dark через `NSAppearance`.

| Токен | Light | Dark | Назначение |
|---|---|---|---|
| `canvas` | `#E5E9EE` | `#101319` | Внешняя базовая поверхность там, где токен применён |
| `surface` | `#FFFFFF` | `#20242B` | Документ, dialog, капсула, поверхности controls |
| `sidebar` | `#F2F4F7` | `#191E25` | Библиотека и её footer |
| `toolbar` | `#FAFBFC` | `#22272F` | Toolbar/player, Settings header/groups, поля |
| `ink` | `#202630` | `#F0F2F6` | Основной текст |
| `muted` | `#626B79` | `#A4ADBC` | Вторичный текст и иконки |
| `line` | `#E3E7ED` | `#353C47` | Границы и разделители |
| `hover` | `#E6EBF2` | `#303844` | Hover и вторичные controls |
| `accent` | `#1762CF` | `#8AB9FF` | Primary action, seek/follow, progress |
| `accentHover` | `#1055B8` | `#A6CAFF` | Hover primary button |
| `primaryButtonForeground` | `#FFFFFF` | `#20242B` | Текст/иконка на accent |
| `selected` | `#E0EBFC` | `#233C5C` | Selected card/tile |
| `selectedInk` | `#164E9E` | `#B0D0FF` | Selected text/icon |
| `green` / `greenBg` | `#27704B` / `#EDF6F0` | `#93D5B0` / `#20392D` | Готовность и успешный результат |
| `warning` / `warningBg` | `#855309` / `#FFF6E5` | `#F0C478` / `#3B3120` | Предупреждение, mute/overtime |
| `red` / `redBg` | `#B82D3D` / `#FBECEF` | `#FF9AA8` / `#402730` | Ошибка, recording dot, stop |
| `track` | `#DCE2EB` | `#404B5B` | Неактивный progress/switch |

`toolbarBackground/text/secondaryText/border/statusGreen/statusAmber/statusRed` —
aliases перечисленных ролей; `avatarPalette` содержит accent/green/warning/red.
Активная реплика смешивает surface с selected на 0.65. Контур выбранной карточки
использует accent opacity 0.12, Settings tile — 0.16. Это не новые hex-токены.
В системных предупреждениях встречаются `.red`, `.secondary`, `.primary` и native
control colors: не подменять их приблизительным hex.

## Геометрия и поверхности

Все размеры — points. Spacing scale `s1…s12`: 4, 8, 12, 16, 20, 24, 32, 40, 48.
Не выводить backing pixels из pt без scale конкретного окна.

| Область | Фактическое правило |
|---|---|
| Workspace | Initial content rect 900×560 в delegate; `window.minSize` 480×500 в `AppWindowState` |
| Library/detail | `RecordingHistoryView`: narrow width ≤767; compact 768…1023; wide ≥1024. Sidebar 264 / 304, body divider отдельно 1. В narrow список занимает всю ширину, detail/back сохраняют общую session |
| Native header | `toolbarHeight=72` — shared constant, не фиксированная измеренная высота native row. `updateHeader` получает высоту из content bounds − `contentLayoutRect.height` |
| Документ | Max frame 840, horizontal padding narrow/compact/wide 16/24/48; top 28/32/40, при width ≥1392 — 48; bottom 28/32/48 |
| Карточка | Radius 10; padding x12/y14, внешний x12/bottom4; group label x24/top16/bottom8 |
| Player | Toolbar background и top line 1; x padding 12/16/28; play circle 44, icon19; waveform hit view height36/minWidth120; `ViewThatFits` переводит controls в две строки |
| Dialog | `ODDialog` width480, transcript edit width560; title/content x24, top24, section spacing20, footer x24/y16, separator1 |
| Settings | Overlay frame `min(760, bounds.width−32)` × `min(740, bounds.height−32)`, floor0; clip radius16, backdrop black opacity0.3 |
| Settings navigation | Shell width ≤600: `ODMenuField`; иначе пять плиток height72/radius10/icon22. Scroll content x20 или32; row y16, group inner x16/radius10 |
| Capsule | Controller держит panel440×64 для recording/processing/overtime; host padding2, content radius24, border1. Recording controls36×36/radius8/icon16; processing close32/icon14; progress4 |
| Reminder | Panel400×220, content392×212 + outer padding4; content padding20, VStack spacing12 |

### Native header и линия колонок

Обычный workspace остаётся titled `NSWindow` с настоящими close/minimize/zoom,
`.fullSizeContentView`, прозрачным titlebar и `.unified` toolbar. Brand и actions
живут в публичных `NSTitlebarAccessoryViewController`, а не в нарисованной копии
светофора. `WorkspaceHeaderHostingView.mouseDownCanMoveWindow=true` сохраняет
native dragging для необработанных кликов.

В nonnarrow режиме `AppWindowState.updateHeader` помещает leading
`Rectangle(ODColors.line)` шириной 1 в тот же видимый actions host, затем actions
шириной `W−S−1`. Outer accessory имеет ширину `W−S`; внутренние actions начинаются
после separator slot и сохраняют right edge. Body divider рисует
`RecordingHistoryView`. Divider декоративный: hit testing выключен, accessibility
hidden. Не лечить seam offset-ами, переносом native controls или перекрывающей полосой.

Narrow list сбрасывает actions root в `EmptyView` при нулевой ширине. Narrow detail
не получает вертикальную линию; `WorkspaceHeaderBackgroundView` заполняет полную
toolbar row и bottom line через public content/layout-guide constraints. Его
`hitTest` возвращает nil, appearance change вызывает redraw. Wide paint там нет.
При работе с layout guide его frame относится к owning view; для сравнения нужны
convert в одну window system, затем `window.convertToBacking` обоих краёв. 1 pt
семантической границы не означает неизменно 1 backing pixel.

### Material и существующие исключения

Workspace, Settings, OD dialogs и recording/processing capsule используют явные
OD backgrounds. Capsule panel прозрачен снаружи формы, `hasShadow=false`; собственная
surface непрозрачна. Это не универсальная glass-капсула.

`MeetingOverlaySurface` применяется к календарному reminder: macOS26+
`glassEffect(.regular, in: shape)`, раньше `.regularMaterial` с контуром
`.primary.opacity(0.08)` шириной1. Default radius24; параметр capsule выбирает36.
Reminder сохраняет native Picker, plain «Пропустить» и `.borderedProminent`
primary button с `.buttonBorderShape(.capsule)`. Это существующее исключение,
а не образец для замены всех OD controls. Специальной ветки reduced transparency
этот modifier не объявляет; фактическую доступность и контраст проверяют отдельно.

## Общие компоненты и взаимодействие

Капсула обработки — `ProcessingCapsuleView`, 420×84 pt: leading 32 / trailing 16 /
vertical 12 pt, зазор текста и кнопки 12 pt. Сверху title 13 semibold, ниже
11 regular «Этап N из M»; до старта — «В очереди · M этапов». Маршрут содержит
5–7 станций по зафиксированным опциям job: узлы 8 pt, линии 2 pt.
Отдельные «далее K», «последний», процент дорожки и локальная
полоса отсутствуют. «Подробнее» использует существующий admission основного окна,
после успеха кнопка называется «Открыть». Manual close/Hide/Escape/⌘W для капсулы
не предусмотрены; terminal timeout и скрытие после accepted Open сохраняются.
Проценты и дорожки находятся в `ProcessingDetailsView` в workspace; неизвестный
total не создаёт долю. Processing UI обновляется дискретными событиями без анимации.

- `ODButtonStyle`: padding12×8, minHeight36 или compact32, radius8; secondary
  border `line`, primary accent без border. Hover меняет fill, pressed opacity0.7,
  disabled0.48. `contentShape(Rectangle())` включает padding в hit region.
- `odInput`: plain field15 pt, padding12×10, toolbar fill/radius8/line border.
  `ODMenuField` использует такую же поверхность, native Menu и chevron10;
  `ODField` задаёт label и gap8. Не заменять Menu декоративной стрелкой без команды.
- Settings имеют локальные варианты: picker13 pt/minWidth124/maxWidth232,
  chevron9/radius8; switch36×22 с thumb16/padding3, disabled0.45 и native Toggle
  accessibility representation. `ODSettingsLabeledStyle` меняет HStack на VStack
  через `ViewThatFits`; disclosure header имеет полный rectangular hit/minHeight28.
- `ODDialog` даёт общий header/scroll content/footer; X имеет icon20 в36×36.
  Focus, disabled и submit/cancel остаются ответственностью caller. В форме и
  editor используются `.defaultAction`/`.cancelAction`, а не отдельная логика undo.
- `ODIconView` рисует Canvas в координатах24×24, stroke1.7 с round caps/joins;
  default size20, screen usages обычно13/14/16/19/20/22/28. Это размер рисунка,
  не hit target. В native menus, reminder и отдельных состояниях остаются SF Symbols.
- Выбор карточки и Settings tile имеет фон/контур; отдельного общего card hover
  style нет. More явно меняет hover fill; остальные plain controls не получают
  автоматически состояния `ODButtonStyle`.
- Disabled вид не заменяет admission: команды повторно проверяют modal/session/job
  identity. Settings выключают hit testing и скрывают background от accessibility,
  backdrop перехватывает click; shell использует focus section, X initial focus,
  Escape не закрывает родительскую modal при дочернем system sheet.
- Иконки-действия получают осмысленные accessibility labels в caller; декоративные
  separator/dot скрываются там, где это явно задано. Scrubber имеет label/value,
  keyboard/adjustable seek. Не считать наличие API доказательством VoiceOver UAT.

## Особенности экранов

**Библиотека и документ.** Общий header, sidebar footer с local-processing note и
Settings button36×36/icon16, независимый нижний player. Empty/loading/no matches/
partial read/processing/warning/error показывают реальные состояния. Редактор
использует current result и saved edits; текста/имени касаются прежние modal guards,
preview/confirm, field undo и Cancel. Saved undo/version selector не добавляются.

**Новая запись.** Sheet через `ODDialog`, meeting и mic selectors, title field,
два meter row13 pt (meter84×18). Ошибка/неподготовленные модели остаются видимыми;
форма не заменяется dashboard последней записи. Settings показываются поверх
mounted формы, её поля/default/cancel временно не действуют.

**Настройки.** Одна overlay на текущем workspace/форме по
[ADR0007](adr/0007-workspace-settings-modal.md); значения сохраняются
автоматически, footer берёт version/build из Bundle. «Запускать при входе» —
действующий SMAppService switch в Основных, с показом ошибок; не переносить его в
status menu. Пять разделов и local styles принадлежат SettingsView.

**Капсула.** Независимый nonactivating floating `NSPanel` по
[ADR0006](adr/0006-independent-workspace-and-recording-overlay.md), общий model/services
с workspace. Background/text используют `WindowDragGesture`, controls сохраняют
свои команды. Положение хранится как frame, восстанавливается и clamp-ится к
visible screens; начальное — по центру сверху с отступом20. Panel присоединяется
к Spaces/fullscreen auxiliary, не скрывается при деактивации. Recording, saving,
processing, completed, error, cancelled и overtime не меняют440×64. Overtime
добавляет warning border1.5 и «+15 мин». Progress отражает события и stage fraction,
без бесконечного декоративного pulse; view transactions отключают animations.
Controller при изменении frame использует свой `animate` argument: это отдельный
native путь, не обещание полностью проверенного reduced-motion поведения.

**Меню.** Status item отправляет оба mouse-up в один native menu route;
`StatusMenu.build` строит NSMenu из текущего состояния. Settings — Cmd+,, quit —
Cmd+Q; размер строк/типографику определяет macOS. More в toolbar — пять
first-level строк: «Повторить обработку», «Переименовать», «Копировать транскрипт»,
«Настройки», затем после разделителя «В Корзину…». Disabled rows сохраняются;
ellipsis icon20 в hit36×36/radius8. У строки библиотеки нет context menu.

**Обновление библиотеки.** В заголовке списка счётчик и `arrow.clockwise`16 в
hit36×36, в narrow — hit44×44. В narrow list синяя «Новая запись» находится перед
поиском; в wide/compact остаётся одна кнопка в toolbar документа. Кнопка,
«Вид → Обновить библиотеку» и ⌘R используют общий guarded command. Во время scan
индикатор занимает ту же область, строка busy/error находится под поиском;
список, query, selection, focus, scroll и текущая session/playback сохраняются.
Ошибка refresh принадлежит запросу и очищается только его повтором.

**Принадлежность сообщений.** Общий feedback библиотеки хранится отдельно от
transient сообщений записи по canonical URL. Баннер объединяет общую ошибку,
сообщение выбранной встречи и её persistenceWarning без одинаковых сообщений.
Поздний terminal event другой записи не меняет видимый feedback. Принятый retry
очищает прежний transient своей записи после workspace admission; отказ сохраняет его.

**Корзина.** У выбранной записи справа зарезервирован hit28×28 для `trash`16;
hover/Tab невыбранной строки не раскрывает эту кнопку. Подтверждение использует
`ODDialog` внутри workspace и блокирует библиотеку и close/hide до отмены или
результата. Delete/Backspace открывают его, Enter подтверждает, Escape отменяет;
pending и повторы не создают вторую операцию. После успеха selection пуста,
focus у соседней строки; первая ↑/↓ или Space открывает её через прежний
library route и возвращает focus библиотеке. Поля ввода и чужие modal/sheet
сохраняют приоритет. Состав папки и возможность восстановления через Finder
объяснены до подтверждения.

**Напоминание встречи.** Собственная floating panel и `MeetingReminderView`,
на системной material/glass поверхности. Вариант во время записи объясняет переход
на следующую встречу. Это не recording capsule и не Settings dialog; не менять
его стиль заодно с общими кнопками.

## Проверка следующей визуальной правки

1. Найти общий helper и реальные callers; сохранить narrow/list/detail transitions,
   native controls, command admission и accessibility semantics.
2. На одной итоговой сборке сравнить полное окно в light/dark и narrow/compact/wide,
   включая длинные русские title/error, disabled/selected/focus и минимальный размер.
3. Проверить настоящим pointer пустые отступы/края controls, клавиатурой Tab/Shift-Tab,
   Escape/default/cancel, затем VoiceOver, reduced motion/transparency и контраст.
4. Для header/panel отдельно проверить native dragging, resize, monitors/Spaces/
   fullscreen и одновременно измеренные same-window/backing edges. Source формула,
   crop или старый снимок не заменяют текущую отрисовку и hit testing.

Это рецепт будущей проверки, не заявление, что все перечисленные состояния уже
прошли UAT. Архитектуру и обязательные сценарии сохраняют принятые ADR и OpenSpec.
