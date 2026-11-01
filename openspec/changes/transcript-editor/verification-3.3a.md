# 3.3a — playback Core + streaming AVPlayer (HIGH accepted after fix1)

Scope: новые Core controller/protocol, AVPlayer transport, 12 fake-transport tests, isolated synthetic smoke. UI не менялся, parent 3.3 открыт. Persisted contracts и producer не менялись.

`TranscriptPlaybackController` на MainActor открывает только явно выбранный `resultID`: валидирует документ, совпадение ID, ready и физический regular/readable mix строго внутри версии, включая symlink resolution. Unavailable не вызывает transport. Missing/corrupt/escaping path дают failed, без fallback на host/master/другую версию и без подготовки AEC/микса. Global seconds без offset/concatenation; seek ограничен duration, nonfinite input игнорируется. Ошибка seek не публикует неподтверждённую позицию. Generation и seek generation отсекают устаревшие результаты, events, close/cancellation.

`TranscriptAVPlayerTransport` использует AVURLAsset/AVPlayerItem/AVPlayer (не AVAudioPlayer и не полную загрузку audio в память). Duration загружается async; readiness ограничена 10 секундами, проверяет cancellation/generation. KVO/notifications передают только Sendable scalar values в MainActor Task, без assumeIsolated. Ready, playing, failed, ended и позиции доступны через protocol events. Periodic observer создаётся только при actual playing и снимается на pause/wait/end/stop/replacement. Владелец обязан вызвать controller.close()/transport.stop() на закрытии; UI lifecycle wiring — 3.3b. Visual follow states — 3.4.

## Test-first

API skeleton скомпилирован, `selectedReadyMixOnly` упал семантически на state/resultID/duration и единственном mix URL: `3.3a-red.log`, exit 1, build success. Не ошибка импорта. До production реализации добавлены 10 тестов, затем расширены двумя close/cancellation regression cases; они проверены GREEN. Нет production fix cycles: первая реализация прошла профильные тесты и smoke.

## Results

- 12 playback tests GREEN; полный suite: **139 tests / 14 suites GREEN**.
- Swift 6 standalone compilation actual Core + actual AVPlayer adapter + `scripts/check-transcript-playback.swift`: exit 0, без diagnostics.
- Real AVPlayer smoke: **9 проверок GREEN** — four-second synthetic silent PCM WAV создан AVAudioFile/PCM buffer, duration, actual start и движение head, стабильный pause, exact seek по общей шкале, ended, periodic events/cleanup, corrupt-media rejection. Ожидания ограничены (readiness <=10 s, smoke checks <=5 s), аудиозапись и installed app не используются. WAV generation ограничена секундным буфером, production использует streaming asset.
- Release build: exit 0.
- Strict OpenSpec и diff check: exit 0 (после отчёта).

Полные baseline, manifest/status, incremental patch, команды и логи: approved OpenCode temp `section3-3.3a`, префикс `3.3a-*`; builder handoff `3.3a-builder.md`.

Не заявлены UI integration, слышимое качество, hardware/AEC UAT, eight-hour performance, dark/light/VoiceOver. Не выполнялись Python/network/install/commit/push/subagents. Независимый review ещё требуется. Parent 3.3 и остальные checkbox не закрывались.

## HIGH follow-up 1 acceptance

Два P2 устранены в fix1: reentrant loading close не вызывает prepare/callback install; playback/seek epochs и end-position validation отклоняют queued/delayed same-item ended после backward seek. Semantic RED до исправления подтверждён fake tests и actual AVPlayer harness. Последний полный suite: **141 tests / 14 suites GREEN**, real adapter smoke **12 GREEN**. Независимо повторены 14 профильных тестов и 12 adapter checks, дополнительный repeated-end/overlapping-seek harness GREEN (три настоящих окончания подряд). HIGH принят, 1/2 fix cycles использован. Evidence: `section3-3.3a/3.3a-high-followup1.md`, `fix1/report.md`, `fix1/high-commands.md`. Это приёмка только Core/adapter; UI не подключён, parent 3.3 открыт.
