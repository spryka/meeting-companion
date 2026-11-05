# Tasks

Текущая стадия: реализация/source release и доставка beta24/build60 завершены;
GitHub и локальный master содержат PR #4. UI заморожен. W/R/M/P реализованы:
открытые составные задачи ниже означают неполную обязательную проверку, а не
неразработанные экраны. Точное сопоставление с release, историческими фазами и
каждым scenario ID — в [verification-release.md](verification-release.md).

Составные задачи с непроведённым UAT остаются открытыми. Scoped source reviews,
202 selected tests и successful install не означают full runtime PASS. Beta23
divider принят только для сообщённого использования; change не архивируется.

| Выполненная часть | Подтверждение / оставшаяся граница |
|---|---|
| W01–W08 workspace/library/current transcript/player/export | Реализация и ограниченные source/regression reviews; native interaction/long/audio residual остаётся в тех же сценариях |
| R01–R08 independent capsule/shared lifecycle | Реализация и scoped state/session/geometry checks; physical capture/drag/Spaces/busy quit UAT открыт |
| M01–M04 единое status menu | Actual `StatusMenu.build`/selectors/admission; полный click/keyboard/concurrency runtime matrix открыт |
| P01–P08 Settings | Одна overlay по ADR0007, live bindings/reset/monitor guards; real devices/calendar/reset/permission/focus UAT открыт |
| Release beta24 | Fresh release build,202 selected GREEN, guards/strict/original signed App+worker; independent review, normal merge, guarded exact install завершены |
| Design guide | [DESIGN.md](../../../DESIGN.md) описывает actual shared roles и screen exceptions; это документация, не новая UI-приёмка |

## RESET-COMMIT1 — current reset admission

- [x] RC1.1 Проверить narrow reset contract/ADR review/strict до behavior; сохранить прежние guards.
- [x] RC1.2 Подтвердить behavioral RED: pending/running/foreign/cancellation отклоняют reset, idle с own flags разрешает; сохранить readiness/state/progress/feedback.
- [x] RC1.3 Учесть accepted handoffs до Task, fresh service reads и sync commit без await; пройти scoped regression. Реальный reset не проверен.
- [x] RC1.4 Actual version recheck, true original App+worker signed package/exact candidate/stableID/leaf, source/cumulative/incremental/preservation/historical artifacts, one freeze/independent review/future exact handoff. Native/full/UAT gaps и failures раскрыть; нового repair round не начинать. Историческое выполнение beta20: [release evidence](verification-release.md).

## SETTINGS-MENU1-CLOSURE1 — VF-026-01–04

- [x] SC1.1 Проверить narrow docs/ADR review/strict до behavior; сохранить accepted ADR и прежние результаты.
- [x] SC1.2 Behavioral RED→GREEN для own Settings reset/check eligibility и actual updater policy; quit/install guards сохранены.
- [x] SC1.3 Behavioral RED→GREEN для form→Settings→close без autostart old monitor; поздние уровни отклонены.
- [x] SC1.4 Behavioral RED→GREEN для сохранённых form callbacks; independent session-bound stop/mute/cancel сохранены.
- [x] SC1.5 Behavioral RED→GREEN для ручного title при calendar publications/expiry; mounted render/input/focus не проверены.
- [x] SC1.6 Fresh scoped Settings/Open/capsule/capture guards и strict; actual version check, true App+worker package/stable signing/exact candidate, patches/preservation/historical artifacts, one freeze/independent review/future exact handoff. Full/native/audio gaps и raw failures раскрыть, нового repair round не начинать. Историческое выполнение beta19: [release evidence](verification-release.md).

## SETTINGS-MENU1 — Settings modal, More4 и VF-025-01

Этот раздел сохраняет контракт Settings modal/More4. Source и synthetic результаты не подтверждают runtime input/focus/render.

- [x] SM1.1 Согласовать Settings modal contract/ADR0007 до behavior; сохранять data и shared lifecycle.
- [ ] SM1.2 После continuation подтвердить compiled expected RED для shared Settings admission/reopen/background commands: все входы, повторный вход без reset, late foreign dismiss, draft/rename/details rejection и сохранение recording-form input. Минимально реализовать owned modal state через существующие model/manager/delegate, затем fresh GREEN; import/environment failure не RED.
- [ ] SM1.3 Адаптировать SettingsShell/visibility и текущий workspace/форму: backdrop, X/Готово/Escape, focus/accessibility, блокировка native-toolbar/keyboard/programmatic действий и поздних callbacks; только settings-owned monitoring/calendar visibility. Проверить безопасными injected providers/monitor/transport без native NSApplication runner, EventKit/device/audio/models/cache/defaults side effects.
- [ ] SM1.4 Оставить в существующем More ровно четыре компактные строки в заданном порядке, labels/icons, rename visible-disabled при unsupported layout, existing retry/copy guards и keyboard/focus/a11y. Удалить только технический пункт из More; context/files/logs/diagnostics/data сохранить. Контракт состава не заменяет pointer/render proof.
- [x] SM1.5 Behavioral RED→GREEN: действительно preloaded result, held late modal rejection не скрывает capsule; следующий accepted Open скрывает свою. Callers используют actual load outcome.
- [ ] SM1.6 Пройти только безопасные relevant Settings/composition/recording-presentation regressions. Реальные overlay bounds/background input/focus/More render в wide/narrow light/dark требуют наблюдения; при прежнем native STOP оставить UNVERIFIED без нового getApp/recovery/grant/driver. Pure visual changes — manual exception, не фиктивный RED; audio/full/UAT gaps сохранить.
- [x] SM1.7 Проверить фактическую следующую version/build, собрать реальный подписанный preview прежним build flow, exact source/candidate/signature/metadata и сохранность старых seals; один freeze, coordinator audit и independent review/dispositions. Только отдельный exact install handoff разрешает runtime delivery с backup/absence/launch guards; без rebuild/resign после freeze. Историческое выполнение beta18: [release evidence](verification-release.md).

## CAPSULE-FEEDBACK1 — owner beta16 feedback

- [x] CF1.1 Compiled Open/admission/ownership RED→GREEN с saved target, modal/invalid/concurrent guards; retained lifecycle сохранён.
- [ ] CF1.2 Implement compact fixed recording/processing/done/error/overtime with ellipsis/full hover/a11y, native passive background/text drag and separate working controls. Native proof requires actual frame delta; unavailable check stays OPEN.
- [ ] CF1.C5 Correct the newly reopened current-fixture light-on-light halo consistently across shared surfaces; preserve pre-C5 package/candidate. Source removal is not final white/dark render proof; native timeout boundary stays in force.
- [x] CF1.3 Build one real signed next preview, exact candidate/source seal, same independent review and guarded exact install handoff. Full/audio/UAT boundaries retained. Историческое выполнение beta17: [release evidence](verification-release.md).

Незакрытые задачи остаются открытыми; исторические результаты не переносятся на текущую ревизию. Подготовка документов не означает выполнение реализации. Для новой проверяемой логики сначала подтвердить поведенческий RED, затем реализовать и пройти регрессию. Для чистой визуальной перестановки записать ручную проверку вместо фиктивных тестов.

## 1. Интеграция SDD

- [x] 1.1 Сверить актуальный checkout, AGENTS.md, CONTRIBUTING.md, основные specs и активные changes. Записать ревизию baseline и известные исходные сбои. Не исправлять их молча вместе с редизайном. Release preflight/source review и current revision/failure map: [verification-release.md](verification-release.md).
- [ ] 1.2 Проверить итоговый импорт/ссылки и провести focused independent review proposal, specs, design и ADR0006. ADR0006 уже accepted 2026-11-04 по явному ответу владельца; это не выполнение implementation/UAT tasks.
- [ ] 1.3 Получить independent review подготовленной DOC-INTEGRATION initial1: три назначенных active specs согласованы с W01/W04 по design.md; snapshot/mode/hash preflight и strict results — external audit текущего run. Проверить сохранение main/ADR0004/0005 guarantees и отсутствие изменений historical acceptance. При будущем изменении main guarantees нужен полный MODIFIED delta в отдельно назначенном path; текущие amendments этого не требуют.
- [ ] 1.4 Сверить HTML с context.md. Проверить предложенный optional displayTitle в прежней metadata/history repository, atomic reload/error/job exclusion/legacy, без path rename и migration. Не вводить иной store/неоговорённый формат и не копировать демологику в продукт.

## 2. Настройки

- [ ] 2.1 Реализовать P01 (Five settings sections) через существующие компоненты. Проверить P01.1: UI harness и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.2 Реализовать P02 (General settings continuity) через существующие компоненты. Проверить P02.1: TDD binding и нативный UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.3 Реализовать P03 (Recording settings continuity) через существующие компоненты. Проверить P03.1, P03.2: TDD binding и audio/folder UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.4 Реализовать P04 (Transcription settings continuity) через существующие компоненты. Проверить P04.1, P04.2: Preparation regression и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.5 Реализовать P05 (Safe owned cache reset) через существующие компоненты. Проверить P05.1, P05.2: TDD reset guards и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.6 Реализовать P06 (Calendar settings continuity) через существующие компоненты. Проверить P06.1: Calendar regression и EventKit UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.7 Реализовать P07 (Diagnostics settings continuity) через существующие компоненты. Проверить P07.1, P07.2: Diagnostics regression и физический UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 2.8 Реализовать P08 (Operation specific locks) через существующие компоненты. Проверить P08.1, P08.2: TDD таблицы разрешений действий. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.

## 3. Рабочее пространство

- [ ] 3.1 Реализовать W01 (Integrated recording workspace) через существующие компоненты. Проверить W01.1: UI harness и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.2 Реализовать W02 (Window width navigation) через существующие компоненты. Проверить W02.1: UI harness и UAT ширины. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.3 Реализовать W03 (Local library search) через существующие компоненты. Проверить W03.1, W03.2: TDD поиска и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.4 Реализовать W04 (Preserve transcript review contract) через существующие компоненты. Проверить W04.1, W04.2, W04.3, W04.4, W04.5, W04.6, W04.7, W04.8, W04.9, W04.10: Регрессия Core/UI и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.5 Реализовать W05 (Current result playback and follow) через существующие компоненты. Проверить W05.1, W05.2: Регрессия player/audio-error и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.6 Реализовать W06 (Export current saved result) через существующие компоненты. Проверить W06.1, W06.2: Регрессия export и UI. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.7 Реализовать W07 (Honest record states and actions) через существующие компоненты. Проверить W07.1–W07.6: UI harness состояний и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 3.8 Реализовать W08 (Native accessibility and long offline review) через существующие компоненты. Проверить W08.1, W08.2: Synthetic long transcript/transport и отдельно доступный physical UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.

- [ ] 3.9 В рамках W04 связать выбор имени с доступным контекстом выбранной календарной встречи и существующим хранилищем правок. Поддержать ручной ввод при отсутствии имён/доступа. Проверить одну реплику и тот же source/voice отсюда до конца, смену источника, старые ручные назначения, preview и отмену до подтверждения; не определять личность автоматически и не менять календарь. HTML использует только демонстрационные имена.

- [ ] 3.10 Rename: expected RED на persistence/reload с saved calendar context, optional displayTitle без потери precise unknown metadata, unchanged no-op, invalid/blank input, atomic save failure, working/admitting race и flat guard; минимальная implementation через прежний repository; GREEN с actual UI caller. Не менять paths/stems/result/edits/context.
- [ ] 3.11 Modal/source scope: expected RED на navigation/retry/close/programmatic admission с input и save error; на remaining anchor/source/voice/manual overwrite/no-op/stale preview. Минимальные shared fixes, затем GREEN через actual production model/service. Saved undo UI исключён; field undo/Cancel отдельно.

## 4. Капсула и окна

- [ ] 4.1 Реализовать R01 (Successful start before hiding workspace) через существующие компоненты. Проверить R01.1, R01.2: TDD переходов и capture UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.2 Реализовать R02 (Independent workspace visibility) через существующие компоненты. Проверить R02.1: TDD lifecycle, AppKit harness и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.3 Реализовать R03 (Rounded capsule and long duration) через существующие компоненты. Проверить R03.1: TDD границ времени и UAT геометрии. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.4 Реализовать R04 (Explicit microphone mute) через существующие компоненты. Проверить R04.1, R04.2: Существующая mute regression и физический audio UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.5 Реализовать R05 (Preserve short cancellation and overtime) через существующие компоненты. Проверить R05.1, R05.2, R05.3: Регрессия short/overtime и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.6 Реализовать R06 (Processing and recovery lifecycle) через существующие компоненты. Проверить R06.1, R06.2: Регрессия queue/progress/retry и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.7 Реализовать R07 (Position focus and Spaces) через существующие компоненты. Проверить R07.1, R07.2: Geometry tests и UAT мониторов/Spaces. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 4.8 Реализовать R08 (Protected quit and install) через существующие компоненты. Проверить R08.1, R08.2, R08.3: Update policy regression и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.

## 5. Меню строки состояния

- [ ] 5.1 Реализовать M01 (Consistent status item click) через существующие компоненты. Проверить M01.1: AppKit harness и UAT. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 5.2 Реализовать M02 (State derived commands) через существующие компоненты. Проверить M02.1, M02.2, M02.3, M02.4: все строки state matrix, допустимую concurrency, stale menu, shortcut/programmatic admission через actual production command boundary; TDD и UAT по requirements-matrix.md. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 5.3 Реализовать M03 (Status icon and shared state) через существующие компоненты. Проверить M03.1, M03.2: TDD presentation/shared identity, mute и показ существующей independent capsule, UAT тем. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.
- [ ] 5.4 Реализовать M04 (Stable utility commands) через существующие компоненты. Проверить M04.1, M04.2, M04.3, M04.4: actual selectors, Cmd+,/Cmd+Q/programmatic routes, workspace/settings hosts и реальные update/termination/modal guards; AppKit harness и UAT по requirements-matrix.md. Для новой логики подтвердить RED перед GREEN, сохранить результат в verification.

## 6. Регрессия и приёмка

- [ ] 6.6 Owner beta11: удалить dashboard последней записи из New; убрать только duplicate model check из Diagnostics; вывести runtime Bundle version/build в общий footer. Проверить actual installed preview, не SwiftPM test bundle.
- [ ] 6.7 Owner beta11: исправить hit shape нарисованных settings tiles/library cards/common buttons/menu fields. Representative wide/narrow blank-padding/edge pointer clicks и disabled case через supported CUA; AXPress/исходники не заменяют pointer acceptance. Недоступный native path оставить OPEN.
- [ ] 6.8 Owner beta11: открыть existing retry на первом уровне обычного меню для eligible standard old/text-only/unsupported entry. Сохранить modal/queue/flat/layout/containment guards; focused nonaudio regression и code-based disposition без user recording/inference/migration.

- [x] 6.1 Выполнить `openspec validate refresh-macos-interface --type change --strict` в целевом репозитории с его intent-driven schema. Исправить документы без ослабления согласованного поведения. Это не проверка реализации. Release strict048 PASS; docs-only closeout strict сохраняется отдельно.
- [ ] 6.2 Выполнить актуальные release build, Swift tests и релевантные self-check из AGENTS.md/README. Отделить исходные падения от регрессий. Приложить команды, exit codes и причины skips. Старые результаты не переносить на новый код.
- [ ] 6.3 Пройти физический UAT в рамках HARD audio <=30 секунд: оба источника, mute, короткая отмена; overtime/длинные границы синтетически, возврат библиотеки, меню, Spaces/fullscreen, мониторы, защита выхода и обновления. Записать macOS, железо, устройства и результаты. Проверить macOS 15 fallback отдельно от материалов macOS 26.
- [ ] 6.4 Пройти обе темы, клавиатуру, VoiceOver, reduced motion/transparency, узкое/широкое окно и синтетический long offline scenario W08.2/streaming transport. Восьмичасовой physical UAT вне текущего разрешения: WAITING_UAT, не запускать и не заявлять PASS. Пропущенные сценарии оставить открытыми.
- [ ] 6.5 Сопоставить каждую строку requirements-matrix.md с тестом или UAT, обновить пользовательские документы и CHANGELOG под Unreleased. Получить ревью и приёмку реализации. Не архивировать непроверенный change. Подпись, установка и выпуск требуют отдельной задачи.

## Текущий порядок проверки

Release sequence выполнена: документация/Info → safe selected tests/release build/
guards/strict → original signed App+worker → independent review → exact source/
artifact/commit binding → normal primary master merge → local fast-forward →
guarded exact install и delivery review. Docs-only reconciliation проходит свой
strict/review до отдельного docs commit, без rebuild/version bump.
Ручной long/audio/accessibility UAT остаётся открытым в этом change. Historical
raw logs вне репозитория; skipped/failed проверки не превращаются в PASS.

# CAPSULE1 focused exception (one pass)

- [x] C1 Behavioral RED→GREEN для terminal job/generation deadlines, retry/queued/working и Hide/reminder ownership.
- [x] C2–C3 Behavioral RED→GREEN для stage fraction, PCM echo counters в процентах и unknown warning/total.
- [ ] C4–C5 one supported isolated native panel cause/drag/exterior check, or exact OPEN blocker without speculative source changes.
- [ ] Signed next preview, frozen source/candidate and preservation; independent audit/review; install only after exact handoff under current guards.
- [ ] HEADER1 actual native wide/narrow light/dark controls/actions/drag acceptance (source composition implemented; single CUA scenario stopped; incomplete007 automatic native test retained separately and removed from regression runner).

## LEAN-SEAM-CLEANUP1 (отдельный pass1/1)

- [x] Прочитать audit032/actual callers, согласовать narrow contract/ADR review до удаления; не переписывать accepted ADR/history.
- [x] Удалить dead technical sheet/private helpers, unbound toggleLogin, legacy morph/exclusive state, obsolete harness/README command/restore assertions; сохранить live routes/data/panel/header/position.  автозапуск Settings callback/initial registration KEEP.
- [x] Сверить existing coverage; перенести только отсутствующие clamp/activation cases, выполнить relevant safe checks/strict.  strict003. Activation/native host assertions перенесены, но не запускались и не заявлены PASS. Explicit no-fake-RED exception для удаления.
- [x] Выполнить разрешённую identity-gated native диагностику либо сохранить точный STOP.  launch/getApp0, seam OPEN/UNVERIFIED, source header unchanged.
- [x] Подготовить actual signed App+worker candidate, preservation/patches/audit и single freeze; independent review и install только после exact handoff. Историческое выполнение beta21: [release evidence](verification-release.md).

## SEAM-CLOSURE1 existing repair1/1

- [x] Лично посмотреть owner full PNG, сверить source body/header ownership с painted receipt и прежние bounds; narrow contract/design/ADR review до behavior. Before9/reservation captured prospectively.
- [x] Продолжить existing semantic divider через public shared header paint owner без root/width/color/control/narrow topology changes. Pure drawing no-fake-RED exception; testsource untouched. line; body HistoryView byte-identical.
- [x] Safe retained checks/strict + final-source host one build/conditional launch с exact reused isolation/probes, свежими source/binary/sameID guards и AFTER bounds; failures STOP/no retries; actual final images либо exact UNVERIFIED gap.  native build006/007 + launch008 PID78971, AFTER wide/compact light/dark root deltas0pt/0px. AFTER raster UNVERIFIED: getApp1/1 exhausted; no alternate capture. Native bounds не являются painted PASS.
- [x] True original App+worker signed next preview, manifests/patches/preservation/onefreeze; independent review FINAL и future exact install handoff. Native/full/UAT/module gaps retain. Историческое выполнение beta22: [release evidence](verification-release.md); painted failure не закрыт этой package-галочкой.

## SEAM-RENDER-CLOSURE1 (отдельный closure1/1)

- [x] Read-only source/layer analysis, новый owner-observed beta22 failure, before9/copies и coordinator disposition; effective assignment/reservation1/1 до behavior, narrow contract/design/ADR review подготовлены. Historical035 source/geometry не raster PASS.
- [x] Перенести existing1pt separator в existing actions accessory, сохранить inner width/position/guards, reuse/reset roots и narrow transitions; удалить duplicatewide content paint, narrowdetail fullrow KEEP.  Pure drawing exception, HistoryView/tests unchanged. Сохранение positions — source relationships, новых measurements нет.
- [x] Выполнить meaningful existing selected safe checks/fresh production compile/strict; native/fixture/getApp0, newgeometry/render/input/drag/a11y UNVERIFIED, не использовать oldbounds как newafter. Исторически7safe checks (4service/3pure); прежние34 model-dependent не повторены из-за eagerEKEventStore. Это не current full PASS.
- [ ] True original App+realworker signed nextpreview/exactcandidate, preservation/patches/audit/onefreeze; independent review/dispositions/future exact install handoff. Владелец принял beta23 divider для сообщённого использования; compound task остаётся открыт из-за broader UAT, это не source-as-painted PASS. Package/review/install часть выполнена исторически: [release evidence](verification-release.md); обязательный residual W01.4/W01.5/W02/W08 сохранён здесь.
