# Визуальная проверка: подтверждения и ограничения

Владелец принял видимый header/sidebar divider в установленной beta23 для
сообщённого использования и разрешил финализацию. UI заморожен. Это не полная
проверка18-row parity, input/drag/a11y/audio или всех window transitions.

## Header и divider

Workspace использует настоящие стандартные AppKit controls и public titlebar
accessories, без reparenting, fake traffic lights или ручных координат кнопок.
В nonnarrow actions accessory ведущий decorative divider владеет существующим
1pt slot. Inner actions сохраняет прежнюю ширину и позицию; narrow list не
получает divider, narrow detail сохраняет full-row background/bottom line.

Прежние wide/compact light/dark public bounds показали согласованные границы:
actions/accessory root у правого края body divider, delta0pt/0px; расстояние
до sidebarRIGHT1pt/2px было самим divider. Это не доказало непрерывный paint.
Beta22 пыталась рисовать линию в contentView background, но владелец подтвердил
новый снимок с прежним белым header slot. Эта попытка остаётся failed painted fix.
Runtime covering/clip cause не доказана. После переноса separator в уже visible
accessory source review был пройден, а beta23 принята владельцем в указанном scope.
Новых native measurements/AFTER images/drag/input/a11y для этой revision нет.

## Остальные области

В reported usage владелец также принимал pointer regions/version, More/halo;
это ограниченные наблюдения, не полная матрица. Более ранние isolated captures
workspace/settings/forms/edits/menu/panel сохраняют свои source/provenance limits.
Снимки до последних правок не выдаются за AFTER, synthetic command tests не
заменяют pointer flow и реальный tray. Старые incomplete summaries, timeout,
noWindowsAvailable, compiler/macro/sandbox failures сохранены в external audit;
они не считаются RED либо успешными действиями.

## Release finalization

Только docs/metadata меняются поверх принятой beta23. Новых host builds/launches,
getApp/CUA, capture paths, recovery или аудио не выполняется. Selected safe tests,
production build, strict и genuine signed App+worker package имеют отдельные
результаты. Исторические7safe checks не переносятся как fresh PASS; старые34
model-dependent checks не повторяются из-за eagerEKEventStore construction.

Полная suite ранее падала на nested SwiftPM sandbox/AAC; исходный boundary check
и window dark-appearance assertion также имели failures. Новая корректная scoped
module check может проверить текущую boundary, но не переписывает старые результаты.
Audio ledger сохраняется:26s generated+copied, conservative remainder4s,
decoder duration UNKNOWN, новая allocation0.

Остаются WAITING_UAT: полный light/dark/wide/narrow/native transition matrix,
input/drag/focus/keyboard/VoiceOver/contrast/reduced motion/transparency,
macOS15 fallback, monitors/Spaces, full/audio/ASR-quality и многочасовой UAT.
Change не архивируется; источник и геометрия не называются painted/product PASS.

## Текущие автоматические проверки finalization

Свежая release build завершена. Выбранные tests:194 Core/Application в21suites,
5pure pipeline assembly и3pure App (всего202), все с complete summaries.
Python-free, оригинальный structured module-boundary checker и Swift finder
self-test завершены успешно в утверждённом scoped context. Это current selected
проверки, не full suite и не runtime UAT. Исходники production/tests/CI неизменны
относительно принятой beta23; настоящие App+worker/signature/package результаты
фиксируются отдельно в release audit. Historical failures и NOT_RUN выше сохранены.
