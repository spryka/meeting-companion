# beta.36: library refresh and recording feedback

Дата приёмки: 2026-11-10. Локальная beta.36/build72; публичный выпуск не выполнялся.

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
