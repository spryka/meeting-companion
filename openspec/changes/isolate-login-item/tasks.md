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
