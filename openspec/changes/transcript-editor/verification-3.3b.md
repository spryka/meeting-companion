# 3.3b — actual window player integration (HIGH accepted)

Scope: TranscriptReviewWindow.swift + новый compiled synthetic harness. Core/adapter/contracts/producer не менялись. Parent 3.3 открыт до HIGH review.

Model владеет controller с real streaming AVPlayer transport. Открытие structured версии асинхронно готовит только её готовый mix, без AEC/смешивания. SwiftUI получает Published state/position/duration/activeTurnIDs. Play/pause, HH:MM:SS, bounded slider и кнопки таймкодов используют те же методы, что synthetic harness. Seek на паузе не включает звук. Interval index подсвечивает все пересекающиеся реплики со stable IDs; autoscroll отложен до 3.4. Нет TimelineView/continuous animations/edit controls.

Переключение сначала готовит новый text/index snapshot, затем вызывает throwing session persistence. Только после успеха старый controller закрывается синхронно (item/observer/callback cleanup), создаётся новый и готовится выбранная версия. Pending task отменяется; закрытый прежний controller и его generation guards не публикуют чужое аудио. Ошибка persistence сохраняет старый text/audio snapshot. Legacy/corrupt/unavailable показывают disabled player и пояснение, TXT сохраняется. Missing mix не скрывает текст. Window close отменяет task, закрывает controller и session, больше не обновляет Published позицию.

## Evidence

- API skeleton успешно скомпилирован Swift 6, semantic RED: `window starts asynchronous player preparation` (exit 133 top-level assertion, red.log; red-compile.log пуст). Не compile failure.
- Actual AppKit/SwiftUI/Core/AVPlayer harness `scripts/check-transcript-player-window.swift`: **16 checks GREEN**, две синтетические PCM WAV версии (4/6 секунд), реальный start/head advancement, pause, seek, ALL-overlap rows, failed persistence, точный actual AVURLAsset URL старой версии, rapid switching, close during prepare, actual nil item/observer/callback, missing mix и legacy TXT.
- Предыдущий actual window harness: **15 checks GREEN**, history/version/legacy/corrupt/lifecycle regression.
- Полный Swift suite: **141 tests / 14 suites GREEN**, новых SwiftPM tests нет; новые integration checks в standalone harness.
- Release build GREEN; strict OpenSpec/diff check GREEN после отчёта.

При implementation compilation исправлен missing return после finite guard в formatter. В расширенном harness сравнение file URL исправлено на canonical (macOS directory URL representation); production не менялся по этому assertion. Это setup corrections, не новые semantic RED или production fix cycles.

Полные baseline/status/manifest, scope plan, команды, логи, incremental patch и integrity: approved OpenCode temp `section3-3.3b`, `builder.md`, `3.3b.patch`, `integrity.log`. 3.3a acceptance docs finalized до snapshot.

Controls имеют accessibility identifiers; физические AX clicks/доступность не проверялись, handlers вызваны программно на actual model в реальном NSWindow. Human listening/AEC/hardware, dark/light/keyboard/VoiceOver/performance UAT остаются 5.2/5.3b. Не запускались installed app, Python, network, install, commit/push, subagents или Gemini. 3.4 follow states и расширенная 3.5 диагностика — отдельно.

## Independent HIGH acceptance

`section3-3.3b/high-review.md`: принято, 0/2 fix cycles. Независимо 16 player-window + 15 window + 7 дополнительных actual-source checks GREEN. Проверены persistence failure при продолжающемся старом playback, синхронное освобождение старого item при успешном switch, stale callbacks после switch/close, exact selected mix URL, finite snapshot, missing/corrupt audio и реальные bound UI handlers. Parent 3.3 закрыт для программного synthetic start/pause/seek; listening/keyboard/VoiceOver UAT не заявлен и остаётся 5.2.
