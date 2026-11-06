# Проверка chronological-transcript-turns

Пилот согласован явным запросом владельца: один writer и независимый read-only
reviewer после связного среза; отдельного builder/прораба нет. База `e460214`.
Передача принята 2026-11-05 22:48:22 UTC; работа родителя в elapsed writer не входит.
Writer: `thr_sdh5mu224h`. Прежний приватный audit и счётчики сохранены.

## S1 — сборка и паузы

- repair_count: 1/2; reviewer: `thr_24urnggzvc`, codex gpt-6.1-sol high, свежий BB child без fork. Финальный S1 PASS.
- RED: 10 assembly tests, 9 ожидаемых assertion failures: insertion, overlap,
  tie order, threshold 1.5, closing punctuation. Exit 1.
- GREEN: 33 tests / 4 suites, exit 0: assembly, grouping, publisher и cancellation.
- Первые попытки родителя остановлены окружением (`sandbox_apply`, затем missing
  `metal`); они не считаются RED. Использован штатный Xcode DEVELOPER_DIR.
- Полные логи и checkpoint в приватном BB thread storage; личных текстов здесь нет.
- ACCEPT P2: закрывающая U+201C отсутствовала в sentence-ending predicate.
  Новый assembly RED воспроизвёл ровно одно падение; исправление и добавленные
  проверки 30 с/неделимого слова/порядка публикации получили GREEN и повторный PASS.

## S2 — оформление и редактирование

- reviewer: `thr_i9eq2rabup`, fresh codex gpt-6.1-sol high; repair_count: 2/2.
- RED на export, generated TXT и App rows/copy; GREEN коротких сценариев.
- ACCEPT P2 (round 1): полный guard базового абзаца подавлял раннюю однозначную
  пару из-за позднего пересечения лимита 30 с. Assembly→export RED, затем локальная
  проверка соседних срезов и GREEN. Добавлены ambiguous old, no-op save и undo/reopen.
- ACCEPT P2 (round 2): переставленные старые turns могли получить маркер через
  промежуточный turn того же голоса. Точный отрицательный RED; все промежуточные
  turns теперь должны принадлежать чужим speakerID. GREEN, повторный S2 PASS;
  оба P2 закрыты, дальнейшие S2 repair rounds не разрешены.
- Ошибки настройки synthetic fixtures (nullable sourceID, displayNumber,
  playback warning) не считаются поведенческим RED. Unchanged raw save остаётся
  no-op по существующей нормализации repository; ошибочное ожидание теста исправлено
  по прочитанному коду, без изменения product contract.

## S3 — единственный focus

- reviewer: `thr_s72zrpy3f6`, fresh codex gpt-6.1-sol high. PASS, coverage repair_count: 2/2.
- RED: App playback/follow, шесть ожидаемых assertion failures.
- GREEN: 23 Core interval/focus/follow tests + App playback test.
- ACCEPT P3: добавлены invalid intervals и старый overlap с сохранёнными edits,
  seek и проверкой неизменности байтов. После уточнения добавлен запрос 5.95,
  непосредственно наблюдающий reversed interval; он прошёл в `s2-r2-green.log`.
- Продуктовая логика после первого GREEN не менялась. Physical APIs возвращают
  все пересечения; focus отдельный и не возвращается к раннему overlap.

## Ранний UI и реальные примеры

- Найден существующий `VisualFidelityTests.solNativeProductionHost` с реальными
  SwiftUI views, синтетическим transport/PCM и PNG. Новый стенд не создаётся.
- Computer Use доступен; осмотрено уже запущенное установленное приложение
  `2.0.0-beta.24`, workspace без активного capture/processing в доступном AX tree.
  Это ещё не показ новой сборки. Установка/перезапуск не разрешены и не выполнялись.
- Native harness вначале упал на `NSInternalInconsistencyException`,
  `titlebarViewController not supported for this window style`: устаревшее
  borderless test window заменено titled production-compatible style.
- Ранний PNG 22:57:47 UTC показывает A→B→A и парные маркеры до S3; тогда ещё
  видна двойная подсветка. Новый playback/focus GREEN получен 22:59:22 UTC.
- Итоговый native harness PASS: PNG `final-ui/workspace-1392.png` осмотрен writer;
  на той же позиции подсвечена только вставка B, A/продолжение не подсвечены,
  парные маркеры видны, компоновка прежняя. Это синтетический UI, не физический UAT.
- Read-only просмотр локальных результатов нашёл вероятный пример отпуска:
  сохранённые turns [110.36,132.50] и [116.56,126.82] пересекаются. В первом
  максимальная соседняя пауза в интересующем окне 1.18 с. Это подтверждает
  overlap в данных, но не причину слышимой паузы: версия producer не записана,
  соответствие скриншоту и аудио не подтверждено.
- Дополнительный read-only поиск по сохранённым displayName нашёл игровой
  результат с указанными владельцем именами: turn начинается в 15.64 с и кончается
  в 36.58 с, согласуется с показанными `00:16`. В районе плеера около 37 с есть
  один элемент `words` [38.40,104.22], длительностью 65.82 с. Producer version
  в JSON не записана. Это конкретная временная аномалия для проверки по звуку,
  не доказательство слышимой паузы. Порог grouping не разрезает отдельное слово.
- План для проверки паузы уточнён: сначала подтвердить запись/producer и
  прослушать локальный фрагмент с исходной дорожкой; если внутри этого word interval
  есть тишина, отдельно согласовать исправление word alignment/recognition.
  Текущая задача не исправляет и не объявляет исправленными растянутые timestamps.
- 1.2 и физический UAT остаются открытыми; изменения ASR/alignment не входят в работу.

## Проверки и границы

- Release build: PASS, 134.33 с; итоговый recheck после последней product правки:
  PASS, 82.57 с, exit 0 (`release-build-final.log`). Сборка не была no-op.
- Python-free: сначала FAIL на 21 старом ignored `.pyc`. Активный Python owner не
  найден; только эти developer caches обратимо перемещены в приватный карантин с
  SHA-256 manifest. Повторная проверка PASS. Записи, edits и model caches не затронуты.
- Module boundaries/package graph: PASS. Recording finder self-test: PASS.
- Strict change validation: PASS. Полный `swift test`: PASS, 398 tests
  (7 vendor + 43 pipeline + 221 Core/Application + 127 App), exit 0.
- S4 итоговый независимый reviewer `thr_fxzp65wk7k`: PASS, repair_count=0/2;
  прежние лимиты S1/S2/S3 сохраняются и не перезапускаются как S4.

### Полный regression: найденные проблемы прежних тестов

Первый полный `swift test` дал 3 issues в 2 App tests, остальные 271 Core/vendor/pipeline
tests прошли. Узкий повтор подтвердил narrow test failure; muted AVPlayer прошёл.

- `repairExplicitOpenShowsNarrowDetailIncludingSameSelection`: в базе `e460214`
  тест включает modal, затем пытается установить list-visible через setter,
  который уже блокируется modal. Продуктовые setter/admission не менялись.
  Предусловие теста исправлено перестановкой двух строк до modal; assertions сохранены.
- `solMutedAVPlayerRateLifecycle`: синтетический клип 0.5 с завершался при конкуренции
  App tests за MainActor, поэтому вместо playing наблюдался paused/rate0. Узкий
  повтор PASS; test-only клип удлинён до 10 с, проверки rate/pause/seek сохранены.

Эти исправления не меняют product behavior; итоговый полный прогон GREEN.

## Оценка пилота

- Первая synthetic версия всех трёх product сценариев: 22:59:22 UTC, 11 минут
  после handoff. Первый осмотренный native PNG: 9 минут 25 секунд после handoff;
  он уже показывал маркеры, а двойная подсветка была явно оставлена до S3.
- Независимые ревью нашли три P2: U+201C и два контрпримера guard маркеров.
  Первый ремонт guard создал новый контрпример той же области. Повторного
  открытия точно того же дефекта нет; считать это одним регрессом при ремонте,
  а не утверждать, что повторных дефектов не было.
- Исправления тестовой подготовки/старого harness/полного suite и ошибки
  окружения разрешены writer без вмешательства владельца. Вынужденных
  корректирующих вмешательств владельца: 0; просьба о reasoning high — настройка,
  а не исправление процесса или требований.
- S1 repair 1/2; S2 repair 2/2; S3 coverage repair 2/2 (product focus без ремонта);
  S4 0/2, PASS. Такой счёт не доказывает постоянного ускорения пилота.
- Runtime usage сохранён как фактические BB context snapshots в приватном storage;
  task token/cost breakdown API не предоставлен. Оценка стоимости по длине текста не делалась.
- Итоговая проверка завершена 2026-11-05T23:16:21.520Z; elapsed writer 28 мин 0 с. Ожидания владельца не было; работа родителя до handoff исключена.

## Итог

S1/S2/S3/S4: независимый PASS; все findings оценены ACCEPT и закрыты
регрессиями/исправлениями либо явно сохранёнными границами UAT. Итоговый reviewer
подтвердил логи обязательных проверок и PNG, test-only исправления приняты.
15/17 tasks проверены; открыты 1.2 и 5.5. Реализация проверена автоматически,
статус физической приёмки `WAITING_UAT`. Change не архивирован.
До отдельного согласования установки commits/push, packaging/release и замена
приложения не выполнялись. Новая группировка применяется только к новым результатам.

## Локальная установка после отдельного согласования

Владелец затем явно разрешил установку и закрытие старого приложения. Собрана
`2.0.0-beta.25`, build `61`, штатным `scripts/build-app.sh`; bundle check и подпись
прошли. Сертификат совпадает с прежним установленным приложением, permissions
не сбрасывались. Копия в install stage побайтово совпала с проверенным кандидатом.

Computer Use трижды вернул `cgWindowNotFound`; владелец отдельно разрешил fallback
`open`/AppKit. Старое приложение завершилось обычным `NSRunningApplication.terminate`,
без force; подтверждены отсутствие приложения и transcription worker перед заменой.
Предыдущий bundle сохранён для отката. Установленный bundle прошёл повторный check
и полное сравнение с кандидатом. После обычного запуска подтверждены новый PID,
правильный executable path и версия/build; доказательство в приватном install log.

Окно новой сборки по-прежнему недоступно Computer Use, native AX-доступ не выдан
и не запрашивался. Установка/запуск подтверждены, физический UAT остаётся открытым.
Перераспознавание пользовательских записей не запускалось; их файлы не менялись.
