# 2.1e — RED process-lock lifecycle: принято

Дата: 2026-10-30. Исходный builder: `google/antigravity-gemini-3.8-flash-high`;
rescue builder: `codex-lb/gpt-6.1-sol`;
независимый reviewer: `codex-lb/gpt-6.1-sol#medium`.

Два теста запускают реальный helper: второй писатель записи A, normal release /
SIGKILL, независимая запись B. После двух Gemini fix cycles оставался blocker
строгого helper resolver и свежей сборки. Пользователь явно разрешил один
дополнительный Sol rescue; независимый reviewer закрыл blocker и принял RED
(`2.1e-sol-rescue-review.md`).

## Проверки

Уникальный scratch `2.1e-sol-rescue-clean-bc31y8yv`: свежие compilation/link helper
и test image, runtime selected helper path только из текущего output.
Lock: 2 runtime RED, exit 1, prerequisite дочернего `acquireWriteLock`
`.notImplemented`; reader: 16 GREEN, exit 0. Reviewer независимо повторил suites
с `--skip-build`. Missing-helper experiment даёт явный `HelperNotFoundError`,
не RED поведения. Выживших helper нет. OpenSpec strict / diff check: exit 0.

## Ограничения

Реализации блокировки нет; lifecycle/isolation assertions недостижимы,
normal release / SIGKILL / per-recording isolation не доказаны. GREEN — в 2.2;
1.0, общая 2.1, 2.2–2.4 открыты. Release/Python/UI/UAT не повторялись.
Setup failures исключены из RED. Сети/install/commit/push/publication не было.

Точные команды, exits, модели и полные логи в W:
`/private/var/folders/p0/09r407rx6ylc_rkx9th9q2pr0000gp/T/opencode/transcript-editor-section2-y36pxxjy/`;
`2.1e-sol-rescue-{builder.md,run.py,clean-lock.log,review-evidence.json,review.md}`;
история: `2.1e-final-review.md`; doc checks: `2.1e-final-*.log`.
Статистика токенов недоступна.
