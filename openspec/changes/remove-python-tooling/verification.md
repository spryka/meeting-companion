# Verification — 2026-11-04

Implemented in `cleanup/remove-python`, based on `56cf8a3`. The former recognizer
remains in `research/swift-mlx-pipeline` at that base. Untracked research PoCs
remain outside this cleanup and are not included in it.

## Checks

- `bash scripts/check-python-free.sh`: RED on the original Python sources;
  GREEN after removing them and the obsolete runtime launcher. No first-party
  `.py`/`.pyc` files or Python interpreter commands remain in source/check/skill code.
- `swift .../find-recording.swift --self-test`: PASS for optional binary plist,
  configured root, latest unfinished recording, legacy flat TXT, ignored
  experiments, log fallback and symlink text. A semantic symlink regression was
  caught and fixed during the Swift port.
- `bash scripts/check-module-boundaries.sh`: PASS; structured graph validation
  now uses Foundation. Existing manifest/import/framework counterexamples and
  six new malformed/dependency cases passed.
- `swift test --skip 'AudioMixerTests|EchoCancellerTests|ModelAssetsTests|ModelVendorGraphTests'`
  with isolated SwiftPM cache/config/security directories: 193 Core/Application,
  28 Pipeline and 15 App tests, **236 total**, exit 0. The new graph test has six
  parameter cases; these are not counted as six additional tests.
- `swift build -c release`: exit 0. Both it and the selected tests ran with
  `python`, `python3` and `uv` replaced by failing commands in PATH.
- `bash scripts/build-aec.sh ...`: PASS using the already cached, SHA-verified
  archive, also with Python/uv blocked. WebRTC remains native C++ with the same
  source (only a comment changed), dependency, compiler flags and DSP settings.
  Helper/library `__TEXT,__text` sections match the previous accepted bundle;
  `THIRD_PARTY_NOTICES.txt` matches byte for byte, including normalized CRLF.
- All 11 JSON fixtures match their former Git bytes; only their location and
  caller paths changed. No installed app, user data, models or preferences changed.
- Live-output and transcription-progress probes compile and pass using their own
  Swift executable as the subprocess fixture, including split UTF-8, oversized
  lines, malformed events and incremental delivery. Bundled-worker probe compiles
  against the current native worker API; it was not executed.
- `openspec validate remove-python-tooling --strict`: PASS.

## Limits

No new audio, inference, model downloads, hardware/permission UAT, signed app
packaging, installation or model/performance parity run. The 22 audio/model
tests were deliberately not rerun; 236 is not a full-suite claim. No runtime DSP,
schema, recording layout or transcript publication change is intended.

The pinned AEC archive is still hosted on PyPI and licenses retain upstream
names, but its Python wrapper/setup is never executed. Historical research and
accepted ADRs may mention Python; they are not current executable dependencies.
The exported skill now requires Swift command-line tools for automatic discovery;
reading a supplied TXT still requires no developer tools. Installed skill copies
outside this repository were not modified.

The initial nested SwiftPM sandbox check failed with `sandbox_apply: Operation
not permitted`; it was rerun through the normal elevated tool permission flow
with caches isolated. No sandbox workaround was added to the project.
