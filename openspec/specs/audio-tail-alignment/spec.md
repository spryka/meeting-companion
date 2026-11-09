# audio-tail-alignment Specification

## Purpose
Единая финальная шкала времени исходных дорожек, безопасное смешивание однофреймового хвоста и сохранность неизменяемых результатов при явно разрешённой повторной обработке.

## Requirements

### Requirement: Finalize a common source timeline

Capture SHALL drain pending conversion output from all WAV/CAF sources before selecting their common final duration, then pad shorter sources with silence and close them. The two16kHz mono PCM16 originals SHALL have equal frame counts and retain captured samples, timestamps, gaps and mute zeros. Finalization SHALL attempt all sources and propagate capture/conversion/write errors.

#### Scenario: Converter emits its final sample
- **GIVEN** host/remote converters have different pending tail lengths, with or without48kHz archives
- **WHEN** capture finishes with a requested duration shorter than the pending audio end
- **THEN** both WAVs end on the same16kHz frame, neither tail is truncated or shifted, archives cover the same final timeline at their rate

#### Scenario: Silent or muted channel
- **WHEN** one source is silent or includes a mute interval and capture finishes
- **THEN** silence remains silence, both sources retain a common end and delayed muted buffers do not become audible

### Requirement: Mix a one-frame tail discrepancy without changing originals

For supported16kHz mono WAVs, AudioMixer SHALL accept a length difference of at most one frame. It SHALL retain the longer length and mix an implicit zero only at the absent shorter tail, without trimming or shifting samples, rewriting inputs or overwriting an existing destination. Mixing SHALL remain streamed and encoded duration SHALL pass the existing decode verification. Differences greater than one frame SHALL remain errors and SHALL not publish a destination mix.

#### Scenario: Either source ends one frame early
- **GIVEN** host or remote is one frame shorter, including when the shorter source ends exactly at a block boundary
- **WHEN** a new mix is prepared
- **THEN** a decodable mix covers the longer source; the last sample is mixed with zero and both original files remain byte-identical

#### Scenario: A meaningful duration mismatch
- **GIVEN** the sources differ by two or more frames
- **WHEN** a mix is requested
- **THEN** durationMismatch is reported and neither sources nor an existing destination are changed

### Requirement: Preserve immutable results during owner-authorized retry

Repair of the affected recording SHALL use the existing explicit retry/publication path, preserve original WAVs, previous committed result and saved edits, and create a new current result. Existing modal/draft, queue, cancellation and busy-install guards SHALL remain in force. There SHALL be no automatic retry, in-place result repair or audio substitution on open.

#### Scenario: Retry the affected recording after the fix
- **GIVEN** the owner explicitly authorizes retry of the affected standard recording
- **WHEN** retry completes successfully in the corrected app
- **THEN** the new current result has playback.ready and a verified contained mix, the old result and original WAV hashes remain unchanged, and playback is available in the actual UI
