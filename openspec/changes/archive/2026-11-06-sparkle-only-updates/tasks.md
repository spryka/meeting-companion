# Sparkle-only updates — единый план

Цель: публичный update-enabled app всегда использует Sparkle, включая Homebrew install; сообщения с brew-командами и detector удалены. Busy/modal, beta opt-in, local updates=false и подписи сохранены.

Согласование: прямой запрос владельца «давай историю с homebrew из приложения тоже уберем; sparkle решает этот вопрос»; реализация ровно в этой границе, без новых требований или UAT/backlog. База: чистый master `72b26af`; текущие beta.30 бинарники не заменяются задним числом.

## Этап

- [x] 1.1 Проверить узкий SDD/ADR manifest независимым read-only reviewer до product edits.
- [x] 1.2 RED на прежний Homebrew admission; удалить три ветки/детектор и его устаревший self-check; GREEN на admission и сохранённых Settings/busy/deferred-install/channel guards.
- [x] 1.3 README/changelog и main spec sync; обязательные проверки, независимый code review на frozen diff, максимум4 ремонта с пересмотром после второго. Это новый запрос после закрытого R5; прежние счётчики сохраняются исторически.
- [x] 1.4 Подготовить следующую отличимую публичную beta штатными scripts и прежней подписью, сохранить доступность опубликованных beta.30 assets. Merge/release выполняются в ранее разрешённых границах, без автоматического stable release или прерывания работающего app.

## Состояние

PLAN_PASS от `/root/review_sparkle_only` (fresh gpt-6.1-sol high) получен до product edits. Source scope — AppUpdater, удаление AppUpdatePolicy/check-app-updates, SettingsPresentationTests и документация. TDD test использует прежний internal homebrewManaged=true только для RED; после удаления ненужного входа проверяет тот же разрешённый idle outcome и сохранение отказа при busy. Никаких моделей/capture/личных записей. Code review ещё не начат, ремонты0/4.

`sparkle-only-red.log`: ожидаемый RED — idle/Homebrew=true rejected с MeetingCompanion.Updates1. После удаления installation-type параметра `sparkle-only-settings-green.log`:27 Settings tests PASS, включая прежние собственные Settings check и блокировку restart. `sparkle-only-lifecycle.log`: beta opt-in, busy guard и deferred installation без forced termination PASS. В Sources/Tests/scripts больше нет Homebrew/Caskroom/AppUpdatePolicy и brew-команд. `sparkle-only-{python-free,boundaries,finder,sdd}.log` и diff-check PASS. Публичная следующая сборка beta.31(67); прежние beta.30 assets не меняются. Release build идёт в `sparkle-only-release-build.log`, затем ordinary full tests; source/docs freeze для code review. Branch fix/sparkle-only-updates.

Initial code review: **PASS**, `/root/review_sparkle_only`, ремонты0/4. Frozen hashes совпали, `.app`/MCEnableUpdates, beta opt-in, busy/modal и deferred-install guards сохранены. Релевантные RED/GREEN/lifecycle логи прочитаны reviewer; итог release/full suite записывается отдельно. Сетевое обновление поверх установленного приложения не выполнялось и не объявляется PASS.

Итоговые проверки: release build `sparkle-only-release-build.log` PASS87.52s; ordinary full `sparkle-only-full-tests.log` exit0:464 Swift Testing (7+45+223+189) +12 XCTest =476. Signed build-app ещё выполняется в `sparkle-only-package.log`; до его exit0 packaging PASS не заявляется. Ранний binary-marker check увидел прежний dist beta.30, а ранний build-dmg остановлен защитой уже существующего beta.30 архива (`sparkle-only-dmg-before-package.log`); это ошибка последовательности owner harness, не product RED новой версии. Повторить только после готовой beta.31. Source/tests/docs соответствуют frozen reviewed версии; позже обновляется только evidence этого плана. PR [#11](https://github.com/spryka/meeting-companion/pull/11), merge после упаковки и проверки архивов.

Финальная подготовка завершена: `sparkle-only-package.log` exit0, затем точно проверены beta.31/build67/updates=true и отсутствие старых Homebrew markers в готовом app. Designated signing requirement совпал с установленным app. `sparkle-only-{dmg,update,payload,appcast}.log` PASS: подписанный ZIP, read-only DMG mount и ZIP payload/cmp, metadata67, beta channel, URL/length, все прежние appcast items неизменны. Ранние проверки предыдущего checkpoint не используются как результат beta.31. DMG SHA256 `c67344197a22c1b019096048e37bcf7942d24c221d458e9856e826859eb15631`; ZIP `6c89eaee048b09255b52bfdddfde704053fb8b2ecf9cdf9550bac6116dd32260`. Основной бинарник7638240B против7639232B beta.30 (−992B); update ZIP−975B. Новые зависимости не добавлены и существующие не удалялись. Реализация и подготовка проверены, SDD синхронизирован; публикация из PR11 и доставка beta-ленты выполняются далее в этом же авторизованном действии. Приложение не устанавливалось поверх работающего экземпляра.

Доставка: PR11 merged в `7a61eb1`; [beta.31](https://github.com/spryka/meeting-companion/releases/tag/v2.0.0-beta.31) опубликована как prerelease, не stable/latest. `sparkle-only-public-delivery.log` exit0: скачанные публичные DMG/ZIP совпали с SHA256SUMS, подпись скачанного ZIP проверена Sparkle sign_update, все три публичных URL отвечают HTTP200. Затем подготовленная лента перенесена в корневой appcast.xml для доставки beta.31. Сетевой in-place install не выполнялся; приложение не заменялось.
