## Context

Принят компактный вариант meeting-reminder-compact.html. Это отдельная presentation правка: её можно реализовать поверх текущего reminder независимо от старого SDD большого варианта. Свежий master для baseline указан в README.

## Goals / Non-Goals

Цель — воспроизвести принятую геометрию без типичного увеличения кнопок, отступов и шрифтов стандартными native styles. Сохранить оба состояния и прежнюю безопасную логику действий.

Не менять capture, обработку, очередь, календарные правила, timeout, формат данных, workspace и capsule. Не переносить browser API или навигацию сравнения в native UI. Не добавлять поиск.

## Decisions

### Источник истины

[reference/geometry.md](reference/geometry.md) задаёт метрики и цвета, [reference/index.html](reference/index.html) — утверждённую компоновку и демопереходы. PNG должны сниматься непосредственно с этого HTML с теми же данными, системным шрифтом и темой; нельзя подменять их рисунком или апскейлом 1×. При обнаружении расхождения таблицы с фактическим cascade сначала уточнить таблицу по эталону, не менять принятый макет незаметно.

### Native rendering

Использовать существующий MeetingOverlaySurface и обычную nonactivating NSPanel. Frame рассчитывать по compact view fitting size; внешняя граница включена в 360 pt. SwiftUI .padding(16) нельзя по ошибке прибавить к уже внешним 360 pt. Прозрачные поля host/panel не должны давать дополнительную видимую рамку/halo. Stroke рисовать внутри внешнего frame, чтобы не получить 361/362 pt.

Размер title, line height, baseline и интервалы задавать явно. Нативная SF typography соответствует системному browser шрифту на macOS; не рассчитывать высоту по приблизительному числу символов. Сохранить fractional leading до финального pixel alignment. Не округлять каждый внутренний промежуток отдельно с накоплением ошибки.

### Состояния

Idle: «Встреча начинается», название, время, основная кнопка «Начать запись», нижняя строка «Другая встреча» / «Пропустить».

Recording: «Следующая встреча», новая встреча и время; затем разделитель и строка «Сейчас: Планирование · 42:18» с точкой (значения из реального state). Основная кнопка «Завершить и начать новую», та же вторичная строка. Обычный поясняющий абзац большого варианта отсутствует.

Для текущей записи короче действующего порога отмены сохранить существующее правило и честное предупреждение о возможной отмене: компактная условная строка «Запись короче 10 секунд будет отменена» размером secondary 12 pt, без обещания сохранения/обработки. Это exceptional native state не показано обычными PNG; оно не меняет геометрию двух основных эталонов и получает высоту по содержимому. Не добавлять постоянный большой поясняющий блок.

### Перенос и ширина

Ширина 360 pt при наличии места; на очень узком экране — доступная ширина минус 16 pt с каждой стороны. Высота по содержимому. Название переносится целиком; font size не уменьшается, line limit и ellipsis не подменяют полный текст. Текущая запись может переноситься, elapsed держать неразрывно. Primary caption переносится при нехватке ширины; минимальная высота не фиксирует максимальную.

При browser viewport до 480 logical px touch targets увеличиваются до 44. Это мобильный режим сравнения; native macOS desktop не должен автоматически превращать все кнопки в 44 pt только потому, что сам reminder имеет ширину 360 pt. Desktop и mobile metrics различать явно.

### Chooser

Отдельный menu/popover у «Другая встреча»: ширина до 336 pt, радиус 12 pt, внешняя граница 1 pt. Строки имеют minimum 52 pt, но фактически растут с line boxes и длинным текстом. Footer «Без встречи» закреплён с разделителем. Родительский frame при открытии списка не меняется. Список ограничен visibleFrame и скроллится; при нехватке места открывается вверх. Полные прежние calendar candidates сохраняются, запись текущей встречи исключается по прежним правилам.

Клавиатура: Up/Down, Enter/Space; Escape/клик снаружи закрывают без изменения выбора, focus возвращается trigger. Убедиться, что focus и позиция выбранной строки доступны при 12+ кандидатах. Родитель скрывается вместе с его chooser при skip/timeout/replacement.

### Lifecycle

Оба действия вызывают существующий startMeeting(selected, expectedSessionID) данного reminder. При записи сначала завершается именно ожидаемая session; затем стартует новая. Предыдущая обычная запись обрабатывается прежним общим путём, short cancellation сохраняется. Guards busy/modal/diagnostic/sessionStarting/sessionStopping не обходятся. Ошибка stop не запускает новую запись, ошибка start не показывает ложный успех. Поздний callback не затрагивает чужую session.

Не добавлять fallback, retry workflows, вторую очередь или session. Skip/timeout закрывают только reminder и chooser, не capture/processing. Автоматический показ не перехватывает focus/Space и не скрывает активную capsule. Меняется только fitting geometry и позиционирование по её действительным размерам.

## Visual Acceptance

Проверить карточку в масштабе 100%, рендер 2×. Внешняя ширина 360 pt, padding 16 pt, границы/разделитель 1 pt и радиусы 16/8/12 pt обязательны; не заменять их «близкими» системными размерами. Измерять frame, а не bounding box тени. Проверить primary width, размер/leading шрифтов, обе оси отступов, обе темы, две обычные ветки и chooser. Fractional browser line boxes не использовать как повод увеличить постоянные отступы; высоту native сверять с теми же данными и настроенным leading.

Визуальный diff может учитывать отличия антиалиасинга SF, но не произвольное смещение блоков, иные размеры controls, толщину линий, обрезание текста или другой перенос. В отчёте показать измерения и отклонения, не ограничиваться «похоже». Проверка размеров не заменяет реальные recording/session проверки.

## Migration Plan

Нет миграции. Реализовать native layout поверх текущих services/handlers. Старые документы и макеты не переписывать; новый compact reference является согласованным эталоном этого change. До реализации актуализировать source map при drift master.

### Drift review 2026-11-18

Свежий origin/master `7a83dd9` отличается от baseline `6529b73e343531545f29a5a0919cbdacba00e428` speaker review и update feed. ReminderView/RecorderAppDelegate не изменились; общий InterfaceStyle затронут speaker review, поэтому его существующее поведение для остальных поверхностей сохраняется. Действующие ADR-0001–0007 повторно проверены, новых решений нет.

В master уже есть `meeting-reminder-ui`. Delta M01 в этом change явно заменяет прежние presentation-тексты/постоянное пояснение на compact; M02–M04 сохраняются без изменений. Основную спецификацию и архив большого макета до отдельного разрешения на синхронизацию/архивацию не переписывать.

Source map: `MeetingReminderView.swift` — view/chooser/presenter; `RecorderAppDelegate.showReminder` — nonactivating NSPanel fitting/clamp; `InterfaceStyle.swift` — существующий MeetingOverlaySurface/line-box helper; `ReminderPresentationTests.swift` — native geometry/snapshots/keyboard; `MeetingTransitionTests.swift` и `CalendarContextRegressionTests.swift` — сохранённые lifecycle guards. Synthetic native тесты переиспользуют существующий `REMINDER_NATIVE_ROOT`, без установки и физического capture.

### Native implementation notes

У существующего MeetingOverlaySurface для reminder применяется solid surface/radius16/strokeBorder1; capsule-вариант сохраняет material/glass. Line boxes reminder измеряют baseline span SwiftUI Text через Layout: прежний общий odLineBox прибавлял leading к уже округлённой native высоте и давал накопленное увеличение. Остальные поверхности не меняются. SF веса650/550 задаются через NSFont.Weight0.33/0.245, без изменения размеров текста.

Chooser — дочерняя borderless nonactivating ReminderPanel, с прежним presenter, выбором и keyboard handlers. Это только presentation вместо системного NSPopover с дополнительным chrome. Панель наследует appearance родителя; owns/dismantles собственные outside-click monitors. Закрытие по outside click не вызывает makeKey родителя; Escape/выбор восстанавливают focus trigger. Parent dismissal освобождает chooser вместе с host. Новых application services/session/store/queue нет.

Внешние тени reminder/chooser рисуются двумя CALayer с rounded shadowPath, цветами/opacity/offset по geometry.md и Gaussian radius40/4 для CSS blur80/8. Прозрачный ReminderSurfaceHost добавляет только область рисования (left/right/top80, bottom104); она не входит в cardFrame/fitting и не получает собственный фон/границу или системную тень. CardFrame и controls clamp остаются прежними; NSPanel paint bounds могут выходить за visibleFrame, чтобы не сдвигать карточку из-за прозрачной тени. hitTest вне card возвращает nil. Открытый chooser синхронизирует appearance через viewDidChangeEffectiveAppearance родительского anchor, включая переключение темы без закрытия списка.

## Open Questions

Продуктовых вопросов нет. Фактические PNG и desktop/light измерения приложены в reference/geometry.md. Native rendering и остальные проверки остаются задачами реализации.

SF baseline калибруется по glyph masks фактических PNG: eyebrow −0.5pt, title/time +0.5pt, chooser time −1pt; offset меняет положение glyphs внутри прежнего line box, не padding/spacing/height. Native weight подбирается по glyph width, а не по числу CSS weight:650→0.33,550→0.245. Измерения до/после сохранены в evidence плана.
