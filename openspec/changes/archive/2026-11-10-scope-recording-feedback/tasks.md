# Предупреждения только своей записи — dev-loop

Цель: сообщение встречи A не показывается над B; позднее событие A также не
загрязняет B. Предупреждение доступно у A, общие ошибки библиотеки не теряются.

Согласование: владелец утвердил план сообщением «да, давай» 2026-11-10;
затем явно одобрил перенос и установку поверх beta.36/library-refresh:
«Да, поверх beta.36». Установленная функциональность сохраняется.

Рабочая копия: существующий отдельный worktree `meeting-companion-trash-recording`.
До подготовки чистый, HEAD `ae643c3`; дерево совпадает с master/origin/master
`19c8424` после fetch 2026-11-10. После утверждения — новая ветка
`fix/scope-recording-feedback` от свежего origin/master; основной checkout и
чужие изменения сохраняются. Baseline затронутых файлов — до правок, вне Git.

## Этапы

- [x] 1. Исправить принадлежность feedback в существующей цепочке App: RED на
  переключение A→B, позднее завершение A при открытой B и сохранение общих ошибок;
  минимальный fix, GREEN и полные обязательные проверки проекта; свежий независимый
  reviewer gpt-6.1-sol/high без истории, read-only, с freeze/hash/diff.
- [x] 2. Собрать подписанный локальный bundle; при утверждении этого плана установка
  входит в объём после PASS и штатного завершения app/worker. Сохранить прежний bundle,
  сертификат и данные; проверить точное установленное содержимое. Owner UI UAT — отдельно.
- [x] 3. Подготовить общий PR к запрошенному слиянию в master: синхронизировать
  основные specs, архивировать оба принятых changes и пройти closeout review.
  Remote merge и обновление checkout — финальные операции после этого PASS.

## Границы

Использовать только synthetic test folders/services. Реальные recordings/results,
metadata, edits и аудио не менять; не запускать capture, модели или retry.
Не менять диаризацию/пороги и не скрывать все сообщения без разбора. Сохранить
selection/current, modal/input/Trash guards и общий библиотечный feedback.
Новых dependencies/store/notification layer не добавлять. VoiceOver/CUA не запускать.
Владелец дополнительно поручил merge в master и закрытие всех specs обоих changes.
Публичный release не входит в задачу. Прежний отказ auto-review для публикации
library-refresh не обходить: новый push/PR оценивается по этому явному поручению.

## Текущее состояние

Подготовлены proposal/spec/design/ADR review; strict validation PASS. План утверждён.
Ветка `fix/scope-recording-feedback`, baseline `19c8424`; исходники сохранены вне Git.
Реализована принадлежность transient feedback URL записи в существующем
RecordingHistory; persistenceWarning берётся из выбранной строки. Общие ошибки
сохраняются отдельно; принятый retry очищает прежний transient только своей записи.
Существующий источник ошибки подтверждён по event handler и общему баннеру;
исходный current JSON выбранной встречи не содержит warning, сообщение принадлежало A.

Проверки: targeted App tests на production events/selection/native host; затем
`swift test --no-parallel`, `swift build -c release`, strict OpenSpec, Python-free,
module boundaries, recording finder self-test, diff-check и signed bundle check.
UI проверка на synthetic host и owner UAT сохраняют разный статус.

RED: `red-production.log` воспроизводит перенос warning и потерю global error;
исходная неудачная AX-проба в `red.log` не считается доказательством RED.
GREEN: `green-final.log` — 5 tests PASS (6 cases). Native synthetic screenshots
до/после подтверждают отсутствие A warning у B и сохранение его у A.
Артефакты: thread-storage `thr_84e42djz54/scope-recording-feedback/`.
UI binding выделен в feedbackError без изменения поведения до meaningful RED.

Reviewer `thr_fv6ueayu66` (fresh spawn, sourceThreadId=null, codex/gpt-6.1-sol/high,
параметры сверены через BB execution event); freeze `feedback.sha256` — 9 файлов,
`feedback.patch` и `new-test.patch`). Initial CHANGES_REQUIRED: ранняя очистка при
последующем отказе modal retry admission. Принято; repair1 RED подтвердил сбой,
очистка перенесена после успешного workspace admission в общий метод модели,
который вызывают production delegate и тестовая конфигурация сервиса.
`repair1-green.log`: 6 tests / 7 cases PASS. Freeze `repair1.sha256` — 10 файлов,
`repair1.patch`, `repair1-new-test.patch`; reviewer PASS repair1, все 10 хэшей и
оба patch совпали до/после, существенных замечаний нет. Ремонты 1/2.
После двух ремонтов —
обязательный разбор причины/сложности перед согласованными максимум двумя extra.
Счётчики закрытого trash-recording не переносятся на новый баг и не переписываются.

Начало подготовки: 2026-11-10 около 17:08 +0300; первая GREEN версия около 17:47.
Strict OpenSpec, Python-free, module boundaries и finder self-test PASS.
Первый запуск full checks заблокирован sandbox-exec; повтор вне sandbox разрешён,
Release/bundle initial freeze PASS. Full test command exit 0, но App лог оборван
посреди теста без итоговой строки: прогон App НЕ считается PASS. После repair1
`repair1-tests.log` завершён: 7 vendor + 49 pipeline + 245 Core + 231 App = 532
Swift Testing и 12 XCTest PASS. Все четыре итоговые строки есть, включая
WorkspaceKeyboardTests. Strict OpenSpec/Python-free/boundaries/finder/diff повторно
PASS на repair1. Release exit 0 и signed bundle `Bundle check passed`
(`repair1-release.log`, `repair1-bundle.log`). Все 10 source/doc hashes повторно
совпали перед установкой.
Точные интервалы ожидания неизвестны. Следующий шаг — результаты full checks/review;
Владелец штатно закрыл приложение, app/worker pgrep exit 1. Установка repair1
остановлена до замены файлов: текущий bundle уже beta.36/build72, а master по
повторному fetch всё ещё beta.35/build71. check-bundle отказал на несовпадении
версии с CHANGELOG этой ветки; сертификат и файлы установленного app не менялись.
Источник beta.36 найден read-only: чистый отдельный checkout library-refresh-work,
коммиты `43e116b` + `3d2691c` поверх `19c8424`; там 20 изменённых файлов, включая
те же App UI/history. Установленный executable SHA256
`fc4b958634d6ff39381affd9ae7981f3dced185687c021c64bbc07caaf31663b`.
Перенос fix поверх beta.36 согласован. Сохранить проверенный fix коммитом,
импортировать ровно `3d2691c` из чистого library-refresh-work и перебазировать нашу
ветку; разрешить пересечения без изменения поведения library-refresh. Затем
проверить feedback + refresh, full checks/review и подписанный bundle. Старый PASS
сохраняется для прежней базы; интегрированная версия требует своих проверок.
Чужой checkout read-only; reviewer прежний, ремонтный бюджет остаётся 1/2.
Логи остановки: install.log, installed-bundle-precheck.log.

Rebase выполнен: beta.36 baseline `3d2691c`, собственный commit `8a419c3`.
Конфликты только CHANGELOG и refresh-метод: сохранены оба пункта и все
request/root/loading/error guards library-refresh; background failure остаётся
global feedback. В existing feedback regression добавлен production manual refresh:
проверяет сохранение session/selection и independent global/A/B feedback.
Library-refresh tasks отдельно отмечают обязательную manual matrix; перед закрытием
отделить доказанные native-сценарии от непройденной ручной приёмки.

Совместная версия: targeted beta36-green.log PASS, все 552 Swift Testing и 12 XCTest
в beta36-tests.log PASS с четырьмя final summaries. Strict обоих changes,
Python-free/boundaries/finder/diff PASS. Reviewer `thr_fv6ueayu66`: beta.36 integration
PASS, 11 hashes и beta36.patch совпали, бюджет 1/2. Source freeze не менялся.
Владелец подтвердил UI-приёмку; физический VoiceOver исключён. В specs сохраняются
только требования и сценарии; подтверждение приёмки хранится в tasks/acceptance.
Следующий шаг: завершить release/bundle, установить, передать PR, синхронизировать
и архивировать оба changes, проверить closeout docs, затем merge/update master.

Release/bundle beta.36 PASS; установка завершена, beta36-install.log exit 0.
Deep/strict bundle check, совпадение сертификата и точное содержимое подтверждены.
Установленный executable SHA256
`5b3c5ef6f162db614e62e9861177549bd10414209a52699e25620b21eb51e413`;
прежний original bundle сохранён в локальной install-backup. Приложение не запускалось.
Итог приёмки без цитат из переписки: [beta36 acceptance](../../../../docs/beta36-acceptance.md).

Closeout подготовлен в общем [PR #18](https://github.com/spryka/meeting-companion/pull/18).
Оба changes архивированы с синхронизацией основных desktop-workspace и
library-refresh specs. 16 основных specs strict PASS, активных changes нет.
README/DESIGN/acceptance синхронизированы; root ADR и принятый source/test код
не менялись. На момент archive незавершённым оставался только административный
пункт closeout review/PR, реализация и её проверки были завершены.
Следующий шаг — read-only closeout review, затем commit/push/merge и проверка master.

Closeout review `thr_fv6ueayu66` — PASS: архивы/specs/ссылки/acceptance корректны,
source7 и staged documentation freeze совпали до/после; существенных замечаний нет.
Бюджет feedback 1/2, library-refresh A 2/2 и B 2/2 сохранён. Все локальные этапы
завершены 2026-11-10; remote merge/update проверяется ведущим после этого checkpoint.
Точные интервалы ожидания, кроме записанных checkpoint, не измерялись.
