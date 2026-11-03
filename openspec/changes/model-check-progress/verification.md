# Verification — 2026-11-04

## Reproduced failures

- Actual `ModelAssets.prepare` with an empty temporary root, downloads disabled:
  first output was only “Подготовка модели gigaam...” after the silent initial
  checksum pass. Regression failed on the expected progress assertion.
- Actual `RecorderViewModel` with controlled Application runner: enqueue during
  dependency checking replaced the live filename and final successful output with
  “Проверка транскрибации…”. Three expected assertions failed. This reproduces the
  owner's exact final-details symptom without reading real models or recordings.

## Verified result

- Initial and final availability checks emit per-file progress before file reads.
  Worker check mode flushes these messages through the existing stdout callback.
- Busy snapshots seed generic diagnostics only on initial attachment; subsequent
  snapshots retain current progress and the completed result.
- Settings displays checking/preparation state and latest output outside Details.
- A controlled production constructor/check/queue flow retains the live filename,
  visible checking summary and successful terminal text through busy/idle snapshots.
- Tiny corrupt-file regression confirms progress precedes file access and the
  exact pinned checksum still rejects corrupt content. No model verification was
  weakened or replaced by mere existence checks.
- **249 selected tests, exit 0:** 193 Core/Application + 28 Pipeline Swift Testing
  + 16 App Swift Testing + 12 synthetic ModelAssets XCTest tests. AudioMixer,
  EchoCanceller and ModelVendorGraph were not rerun. This is not a full-suite claim.
- Final release/packaging rebuilt after the code changes; deep/strict signature
  and bundle checks passed. The earlier beta9 package was not installed.
- Actual signed packaged worker `--check --model-root TEMP` emits all 10 file
  progress lines and exits 1 for a tiny corrupt manifest. No real model weights,
  inference, downloads or audio were used by the agent.
- Installed **2.0.0-beta.9/build45** over beta8/build44 after the owner closed the
  app and live process guards confirmed no App/Worker/AEC/CLI activity. The full
  244-entry installed manifest (files, directories, modes, symlinks) matches the
  signed source bundle. ID `local.meeting-companion` and Authority
  `Interview Recorder Code Signing` retained; old app removed only after validation.
- Native UI launch displays `v2.0.0-beta.9`; Settings → Transcription opens and
  reports “Готово”. Check on the real model directory was not rerun by the agent;
  its streaming behavior is covered by the actual runner and synthetic worker checks.
- `openspec validate model-check-progress --strict`, the Python-free check and
  whitespace validation passed.

No recording, model cache, user settings, permissions or original audio were
modified by this fix/installation. The user independently finished their live
recording before installation. Raw logs and installation evidence are retained
in the coordinator's `python-cleanup` thread artifacts.
