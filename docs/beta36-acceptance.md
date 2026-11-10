# beta.36: library refresh and recording feedback

Первичная приёмка: 2026-11-10, локальная beta.36/build72. На этой стадии публичный
выпуск не выполнялся. Подготовка публичного build 74 описана в дополнении ниже.

## Поведение

- Обновление библиотеки: кнопка, меню «Вид» и ⌘R используют одну guarded command,
  сохраняют открытый документ, query/selection, focus/scroll и playback.
- Восстановленная папка обнаруживается обычным scan без ASR, миграции или pruning.
- Предупреждения и ошибки записи показываются только у выбранной встречи.
  Поздние события другой записи не переносят сообщение в её транскрипт.
- Общая ошибка библиотеки и refresh error независимы от feedback записи.
  Успешный retry очищает прежнее transient сообщение после admission;
  отказ admission сохраняет его.

## Проверки и приёмка

Совместная база — `3d2691c` (library-refresh, beta.36/build72), код исправления —
`8a419c3`, integration regression — `f6637e7`.

- `swift test --no-parallel`: 552 Swift Testing (7 vendor, 49 pipeline, 251 Core,
  245 App) и 12 XCTest PASS, с итоговыми строками всех targets.
- `swift build -c release`, `scripts/build-app.sh` и signed bundle check — PASS.
- Strict validation обоих changes, Python-free, module boundaries, recording finder
  self-test и diff check — PASS.
- Native regressions покрывают feedback A/B, позднее событие, пустой выбор,
  принятый/отклонённый retry, persistence failure и manual refresh с сохранением
  той же session/selection. Снимки native host показывают warning у A и его отсутствие у B.
- Независимое source review и review интеграции beta.36 — PASS; ремонт feedback 1/2.
  Прежние бюджеты library-refresh A 2/2 и B 2/2 сохранены.
- UI принят владельцем. Физический VoiceOver исключён из приёмки и не запускался;
  native announcement path сохранён. Захват и качество аудио этим изменением не проверялись.

Тесты используют synthetic folders/services. Реальные recordings/results/edits,
настройки и разрешения не изменялись. Установленный bundle совпал с проверенным
кандидатом; сертификат прежний, предыдущая beta.36 сохранена для возврата.

Контракты: [library refresh](../openspec/specs/library-refresh/spec.md),
[desktop workspace](../openspec/specs/desktop-workspace/spec.md).

## Дополнение: сверка библиотеки и публичная beta.36

2026-11-10 установлен build 73 с удалением исчезнувших записей при полном scan.
Владелец проверил обновление и подтвердил: "работает!". Предыдущий запрет
pruning заменён принятым L02: ошибка чтения, работа, параллельные изменения
и ввод сохраняют защищённые строки. Восстановление папки обнаруживается
следующим обновлением без ASR.

Итоговый код прошёл release build, 559 Swift Testing tests в 47 suites и 12 XCTest при
последовательном запуске, проверки Python-free, module boundaries, finder
и strict OpenSpec validation. В первом общем прогоне два UI/тайминг-теста
дали плавающие сбои. Оба прошли отдельно и в полном последовательном прогоне
без изменения assertions и порогов времени. Подпись установленной сборки
совпала с прежней; manifest файлов записей сохранился после установки и запуска.

Публичная beta.36/build74 объединяет принятые beta.33-beta.36. Для неё включён
Sparkle beta-канал, подготовлены DMG и подписанный ZIP. Историческая приёмка
beta.33-beta.35 остаётся в [отчёте beta.35](beta35-acceptance.md).
Apple notarization, новая запись, подготовка моделей и транскрипция этим выпуском
заново не проверялись. Прежние исключения физического VoiceOver сохраняются.
