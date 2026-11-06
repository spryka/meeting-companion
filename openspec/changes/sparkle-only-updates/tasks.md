# Sparkle-only updates — единый план

Цель: публичный update-enabled app всегда использует Sparkle, включая Homebrew install; сообщения с brew-командами и detector удалены. Busy/modal, beta opt-in, local updates=false и подписи сохранены.

Согласование: прямой запрос владельца «давай историю с homebrew из приложения тоже уберем; sparkle решает этот вопрос»; реализация ровно в этой границе, без новых требований или UAT/backlog. База: чистый master `72b26af`; текущие beta.30 бинарники не заменяются задним числом.

## Этап

- [x] 1.1 Проверить узкий SDD/ADR manifest независимым read-only reviewer до product edits.
- [x] 1.2 RED на прежний Homebrew admission; удалить три ветки/детектор и его устаревший self-check; GREEN на admission и сохранённых Settings/busy/deferred-install/channel guards.
- [ ] 1.3 README/changelog и main spec sync; обязательные проверки, независимый code review на frozen diff, максимум4 ремонта с пересмотром после второго. Это новый запрос после закрытого R5; прежние счётчики сохраняются исторически.
- [ ] 1.4 Подготовить следующую отличимую публичную beta штатными scripts и прежней подписью, сохранить доступность опубликованных beta.30 assets. Merge/release выполняются в ранее разрешённых границах, без автоматического stable release или прерывания работающего app.

## Состояние

PLAN_PASS от `/root/review_sparkle_only` (fresh gpt-6.1-sol high) получен до product edits. Source scope — AppUpdater, удаление AppUpdatePolicy/check-app-updates, SettingsPresentationTests и документация. TDD test использует прежний internal homebrewManaged=true только для RED; после удаления ненужного входа проверяет тот же разрешённый idle outcome и сохранение отказа при busy. Никаких моделей/capture/личных записей. Code review ещё не начат, ремонты0/4.

`sparkle-only-red.log`: ожидаемый RED — idle/Homebrew=true rejected с MeetingCompanion.Updates1. После удаления installation-type параметра `sparkle-only-settings-green.log`:27 Settings tests PASS, включая прежние собственные Settings check и блокировку restart. `sparkle-only-lifecycle.log`: beta opt-in, busy guard и deferred installation без forced termination PASS. В Sources/Tests/scripts больше нет Homebrew/Caskroom/AppUpdatePolicy и brew-команд. `sparkle-only-{python-free,boundaries,finder,sdd}.log` и diff-check PASS. Публичная следующая сборка beta.31(67); прежние beta.30 assets не меняются. Release build идёт в `sparkle-only-release-build.log`, затем ordinary full tests; source/docs freeze для code review. Branch fix/sparkle-only-updates.

Initial code review: **PASS**, `/root/review_sparkle_only`, ремонты0/4. Frozen hashes совпали, `.app`/MCEnableUpdates, beta opt-in, busy/modal и deferred-install guards сохранены. Релевантные RED/GREEN/lifecycle логи прочитаны reviewer; итог release/full suite записывается отдельно. Сетевое обновление поверх установленного приложения не выполнялось и не объявляется PASS.
