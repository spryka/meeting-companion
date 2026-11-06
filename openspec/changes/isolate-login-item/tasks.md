# Изоляция автозапуска от тестового host — единый план

Цель: служебные hosts не создают login items; автозапуск настоящего .app сохранён. План согласован владельцем ответом «давай» после ссылки на login-helper-plan.md; этот файл заменяет подготовительный checkpoint и является единственным планом реализации. База: clean master 47ed5b6. Старт: 2026-11-06T20:06:01Z.

## 1. Один ремонт

- [x] 1.1 Прочитать callers/ADR, определить executable helper и подготовить узкий SDD по согласованному плану.
- [x] 1.2 Подтвердить RED через fake registrar/isolated defaults без системной регистрации.
- [x] 1.3 Ввести общий admission startup/Settings; GREEN matrix для helper/чужого app/packaged public/local app, marker, manual toggle и ошибок.
- [x] 1.4 Выполнить обязательные проверки и независимое read-only ревью frozen diff; максимум2 ремонта. Sync spec после GREEN, без изменения accepted ADR.

## Состояние

SDD подготовлен до product edits; PLAN_PASS от /root/review_login_item (fresh gpt-6.1-sol high) получен до извлечения/изменения production логики. Файлы baseline: RecorderAppDelegate.swift, SettingsView.swift, SettingsPresentationTests.swift, CHANGELOG.md; чистые в 47ed5b6. AppLoginItem и отдельные tests — новые. Исходный путь helper подтверждён rg --files в Xcode; точная существующая запись не подтверждена (sfltool dumpbtm authorization failed, Code=-60002).

TDD: прежние startup/manual операции без identity guard извлечены в AppLoginItem и оба caller переведены на них до RED. login-item-red.log: exit1, 28 ожидаемых issues в unsupported-host/actual-host tests; fake registrar вызван и marker изменён. Остальные настройки, ручные команды и ошибки PASS. Начальный sandbox launch не смог собрать manifest (sandbox_apply: Operation not permitted), записан отдельно в login-item-sandbox.log и не считается RED. Затем добавлены положительный guard перед status/preferences/commands и disabled Settings control; GREEN ожидается.

GREEN: login-item-green.log exit0, 33 tests/2 suites (6 новых функций, 12 cases +27 Settings tests). Реальный test Bundle.main: XcodeDefault.xctoolchain/usr/libexec/swift/pm, id=nil; теперь он не читает service/status и не меняет marker. Положительные public/local .app cases используют синтетические identity и fake service, не реальные регистрацию/launch. Main spec M05 синхронизирован точно с delta. Source/tests/docs frozen для initial code review; полные проверки идут отдельно. Reviewer /root/review_login_item, code repairs0/2.

Системные preferences/login items не меняются. Удаление helper требует отдельного подтверждения его identity и разрешения; публикация/установка beta в этот ремонт не входят. Capture/models/calendar/личные записи не запускаются. Нет требований на ранее снятую владельцем широкую UAT.

Итог: независимое ревью /root/review_login_item — PASS, ремонты0/2, все10 frozen hashes совпали. login-item-release.log exit0 (124.59s); login-item-checks.log exit0 (python-free, module boundaries, finder self-test, strict SDD, diff-check). Обычный полный первый прогон login-item-full-tests.log exit1: единственный issue — неизменённый timing-тест W08, 5.324994125s при лимите5s. Код и threshold не менялись. Exact focused rerun login-item-timing-focused.log exit0, 0.651082416s. Повторный обычный полный swift test без --no-parallel — login-item-full-rerun.log exit0:470 Swift Testing (7+45+223+195) +12 XCTest =482; W08 4.933083875s. У timing-теста остаётся чувствительность к нагрузке; это не выдаётся за новый подтверждённый product defect и не создаёт отдельного обязательства этого ремонта.

Проверенный результат: actual SwiftPM host с id=nil не допускается к fake service/marker; supported .app сохраняет automatic/manual success, disabled preference и error/retry semantics. Реальные ServiceManagement операции и существующая запись macOS не проверялись и не изменялись. Release artifact/установка не выполнялись. Ведущий написал код, reviewer работал read-only; повторные прогоны не считались code repairs.

Проверки и ревью завершены: 2026-11-06T20:17:44Z. Первая GREEN версия — login-item-green.log; точное время готовности и интервалы ожидания отдельно не замерялись.

## 2. Документация и beta.32

Дополнение согласовано прямым запросом владельца: «обновим документацию уберем упоминание homebrew и все смержим соберем и я скачаю новую версию и установлю ее себе». Установка остаётся за владельцем. База source/tests: reviewed commit6dc5451. Повтор полного suite не нужен при неизменных Source/Tests; заново проверяются документация/метаданные, подписанный публичный bundle, архивы и доставка. Это документационная очистка без изменения поведения M04; отдельный SDD для переформулировки не требуется. Исторические changelog/appcast entries и архивы не переписываются. Новый reviewer этапа2, максимум2 ремонта, source repairs0/2 сохраняются исторически.

- [x] 2.1 Убрать текущие инструкции пакетного менеджера из README/CONTRIBUTING и названия из main M04 без изменения контракта; beta.32/build68, changelog.
- [x] 2.2 Собрать подписанный update-enabled .app, DMG и Sparkle ZIP штатными scripts; проверить payload, metadata, подписи и сохранение прежних feed items; независимое read-only ревью frozen docs/release snapshot.
- [x] 2.3 Смержить source/docs через обычный PR; опубликовать beta.32 как prerelease, сохранив stable latest и прежние assets; проверить публичные скачивания.
- [ ] 2.4 Подготовить проверенную beta-ленту и финализировать SDD через отдельный PR; проверить live feed и clean master после слияния.

Уточнение упаковки: первый prepare-update завершился с сообщением removed1old update; beta32-feed-pruning-red.log подтвердил потерю build20 (старые builds67,66,36,35,34,20; кандидат68,67,66,36,35,34). Локальный generate_appcast --help документирует --maximum-versions0 как сохранение всех items; в штатный script добавлен этот аргумент, без новых веток/зависимостей или смены политики каналов. Пересоздаётся только ещё не опубликованный updates/2.0.0-beta.32 (два перечисленных generated файла). Это исправление упаковки для согласованного сохранения прежней ленты, не изменение App Source/Tests. Ранние ошибки harness (поиск Swift mangled symbol без demangle, импорт отсутствующего на macOS FoundationXML) исправлены в проверках и не считаются product RED.

Packaging GREEN: beta32-package.log exit0 (app build11.81s, worker122.62s, check-bundle/signatures PASS), beta32-binary.log exit0 (beta.32/build68/updates=true; AppLoginItem linked; designated requirement равен установленному app). beta32-dmg.log и beta32-update.log exit0; исправленный generate_appcast removed0old. beta32-feed-green.log: 6предыдущих XMLitems без изменений +build68, platform/channel/URL/length и реальная ZIP signature PASS. beta32-payload.log: diff -qr всех файлов подписанного кандидата с ZIP и read-only DMG payload +check-bundle PASS, временные mounts/files очищены. beta32-sdd.log13/13PASS. Frozen manifest beta32-frozen.sha256, code/docs diff beta32-frozen.diff; reviewer /root/review_beta32 проверяет этот snapshot. Никакого app launch/in-place install или очистки системных loginitems не выполнялось.

Этап2 independent review: PASS /root/review_beta32, ремонты0/2. Все18hashes совпали, сохранение signing identity/key/channel и полных payload подтверждено; --maximum-versions0 принят по RED→GREEN. Публичная доставка/livefeed/stablelatest пока не заявляются PASS. DMG SHA256ca81f9dca656243f07bce9a4a00d49c089f2735a1350c72456a5fb2481b9c72a; ZIP7451dd713fdba49fadcfe55e2d92474f85a2deb2b01a30ffe39f5240688c1b37.

Доставка: [PR13](https://github.com/spryka/meeting-companion/pull/13) merged75b17413c05d22f2cda32e172e9cb5044c9a8909; tag/release [beta.32](https://github.com/spryka/meeting-companion/releases/tag/v2.0.0-beta.32) опубликован из этого commit как prerelease. Все18frozen hashes проверены после checkout master. Stable latest после публикации остаётся v1.7.2. beta32-public-delivery.log exit0: скачанные DMG/ZIP совпали с опубликованным SHA256SUMS, подпись скачанного ZIP проверена, все3публичных URL HTTP200; временные downloads удалены. Root appcast скопирован из проверенного кандидата, его доставка через отдельный PR идёт далее; live feed ещё не заявляется PASS. Установленное приложение и существующая системная запись не менялись.
