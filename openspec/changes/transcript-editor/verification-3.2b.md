# Verification 3.2b — AppKit integration (HIGH accepted)

История получила действие «Открыть расшифровку». App delegate направляет его в `TranscriptReviewWindowManager`, а выбор версии — в live `RecordingHistory.selectResultIDThrowing` через weak callback на MainActor. Действие капсулы «Открыть результаты» не менялось.

Manager удерживает реальные NSWindow и delegates по canonical recording URL, использует Core coordinator; повторное открытие поднимает существующее окно без смены закреплённой версии. Закрытие очищает registry, delegate callback и session persistence callback, не затрагивая другое окно. Представление read-only: название, валидированные версии, lazy строки со стабильными turn ID, сохранённые text/displayName overrides или Speaker N. Legacy TXT явно обозначен как read-only, без editing/player/seek controls. Corrupt/unavailable fallback не скрывает ошибку.

При переключении сначала загружается документ с matching resultID и edits, затем выполняется throwing persistence и только после успеха публикуется новый view. При ошибке старый view остаётся; ошибка показана отдельно.

## Test-first and verification

- Runtime skeleton с точной production API скомпилирован успешно; actual AppKit harness завершился semantic RED: `TranscriptWindowError.transcriptNotFound("3.2b not implemented")`, exit 133 из-за top-level Swift error. Это не compile/import failure.
- После реализации первая попытка harness выявила ошибку synthetic fixture: изменён итоговый текст при неизменном baseline и disabled correction. Исправлен только fixture builder; этот setup failure не считается новым RED или production fix cycle.
- `scripts/check-transcript-window.swift`, скомпилированный с пятью actual Core sources и actual AppKit/SwiftUI implementation: **15 проверок GREEN**, реальное создание/показ/закрытие NSWindow. Проверены selection failure/success, disk persistence, pinning при новой версии, canonical repeat, saved overrides, callback cleanup, независимость окон, legacy, corrupt/unavailable fallback.
- Полный `swift test` с явным TestingMacros plugin, `--disable-automatic-resolution --skip-update`: **127 tests / 13 suites GREEN**.
- `swift build -c release --disable-automatic-resolution --skip-update`: exit 0.
- `openspec validate transcript-editor --strict`: exit 0.
- `git diff --check`: exit 0 (последняя проверка после отчёта).

Полные команды, логи, baseline manifest/copy и incremental patch находятся в approved OpenCode temp `section3-3.2b`: `plan.md`, `3.2b-red-compile.log`, `3.2b-red.log`, `3.2b-green-compile.log`, `3.2b-green.log`, `3.2b-tests.log`, `3.2b-release.log`, `3.2b-openspec.log`, `3.2b-diffcheck.log`, `3.2b-integrity.log`, `3.2b.patch`, `commands.md`.

Установленное приложение не запускалось/не завершалось, audio/hardware/network/Python/install/commit/push не использовались. Harness вызывает тот же model transition, что Binding picker; физические клики и внешний вид не проверены. Dark/light, keyboard/VoiceOver и performance UAT остаются 5.2/5.3b. Audio 3.3–3.5 и editing 4 не реализованы здесь.

## Independent HIGH acceptance

HIGH review принят без блокирующих замечаний и без fix cycles (`section3-3.2b/3.2b-high-review.md`). Независимо скомпилированы actual AppKit/SwiftUI/Core sources: 15 basic и 13 дополнительных проверок с actual RecordingHistory GREEN. Corrupt result/edits сохраняют прежнее состояние без persistence; throwing history adapter проверен на успех и ошибку. Symlink canonical focus, stale callback, UTF-8, invalid encoding, literal TXT, escaping symlink rejection проверены. Actual NSApplication loop с autoreleasepool drain подтвердил освобождение window/model/state/session и независимость другого окна. Parent 3.2 закрыт только для basic actual AppKit flow; visual/VoiceOver и audio UAT не заявлены.
