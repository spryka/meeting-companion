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
- [ ] 2. Собрать подписанный локальный bundle; при утверждении этого плана установка
  входит в объём после PASS и штатного завершения app/worker. Сохранить прежний bundle,
  сертификат и данные; проверить точное установленное содержимое. Owner UI UAT — отдельно.

## Границы

Использовать только synthetic test folders/services. Реальные recordings/results,
metadata, edits и аудио не менять; не запускать capture, модели или retry.
Не менять диаризацию/пороги и не скрывать все сообщения без разбора. Сохранить
selection/current, modal/input/Trash guards и общий библиотечный feedback.
Новых dependencies/store/notification layer не добавлять. VoiceOver/CUA не запускать.
Merge, публикация и закрытие SDD — после проверки и отдельного решения владельца.

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
Owner UAT не выполнена. Логи остановки: install.log, installed-bundle-precheck.log.
