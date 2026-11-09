## Context

SourceAudioFiles reads host/remote.duration before drainConverter. A1s synthetic48kHz input48002frames reproduces16001/16000final frames. The affected76min recording differs73364622/73364621; its original text/result remain valid, playback.unavailable.

## Goals / Non-Goals

Goals: equal new capture ends, narrowly tolerate one-frame existing tails, restore the affected player's audio via owner-authorized retry. Non-goals: new repair UI, new result format, edits transfer, model/algorithm changes, migration, removal, publication or archive.

## Decisions

SourceAudioFiles drains every source, including optional archives, collects errors, then computes max(requestedDuration, all drained durations), pads and closes every source. Reuse SourceAudioFile.drainConverter with file visibility; standalone finish remains safe. Choosing duration before drain is rejected because converter state can add a sample after that choice. Truncation is rejected because it loses audio.

AudioMixer accepts max(lengths)-min(lengths)≤1 and iterates to the longer length, reading each block and treating missing tail samples as zero. Validate each actual read against its expected remaining frames before mixing; do not read stale buffer values at EOF. Keep AAC decode verification, temporary cleanup and immutable destination/source guards. No general tolerance or long silence fallback. This supports existing recordings without rewriting WAVs; capture fix prevents recurrence in new recordings.

Use existing PipelineTests' Platform dependency for @testable source-finalization regression; existing AudioMixerTests for both shorter directions, one-frame block boundary,2+frames rejection, duration/decode and input byte preservation. No new target or dependency.

## Risks / Trade-offs

Drain errors must not skip closing other sources → preserve aggregate error handling. Archive48kHz rounding differs from WAV16kHz → compute common end only after all drains and assert equal frame counts within each rate. EOF buffers can contain prior block data → length-guarded samples and exact-read checks. Retry reruns models → explicitly authorized by owner, old result retained; use normal application path instead of inventing remux publication.

## Migration Plan

No data migration. Local beta.35/build71, same ID/signing requirement, review exact candidate before normal guarded Quit/install, preserve beta.34 rollback. Retry only the affected recording after install, verify immutable source/old-result hashes, current playback.ready, UI player and real transport progress. Existing manual edits, if any appear before retry, remain in the old version and are not copied automatically; recheck draft/edits before dispatch.

## Open Questions

None blocking. Physical capture/mute/device switching remain separate UAT; synthetic finalization does not claim hardware acceptance. Source buffers of the historical recording were not logged, so exact historic callback order is unknown.
