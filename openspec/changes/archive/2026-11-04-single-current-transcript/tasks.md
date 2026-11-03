# Implementation and verification

- [x] 1. Resolve current directory before schema validation; ignore selection/format markers, preserve unknown metadata and disk reloads.
- [x] 2. Stage mandatory per-result text/audio/JSON; directory rename is the only commit; root export is derived and warnings retain committed current.
- [x] 3. Remove recognition history/switch APIs and UI; keep text/name edits, playback/export and close protection.
- [x] 4. Gate every GUI retry through shared Application admission; resolve drafts before enqueue, close old editor, block reopen through terminal teardown.
- [x] 5. RED/GREEN actual boundary tests, synthetic publication/service/reopen, source immutability; compile affected UI harnesses.
- [x] 6. Final complete Swift tests, release/sign beta.6/build42, boundary/OpenSpec, source/patch/artifact evidence; no install.
- [x] 7. Independent acceptance and owner GUI UAT completed on beta.8/build44: recording/transcript/audio, persistent word/name edits, draft admission/reprocessing and cancel/retry.

Historical beta.6 author verification (candidate CHANGES_REQUESTED; not proof of cutoff):
full 240 Swift tests (189 Core/Application, 11 App,
23 Pipeline, 7 Vendor, 10 Assets), all release products, three harness compiles,
evaluated transitive graph, strict validation of this change/native runtime/editor,
deep strict signature and check-bundle passed. Exact commands/logs, semantic RED
qualifications, incremental patch/manifests and beta.6/build42 hashes are in external
`completion-native-only/single-result-simplification/final-report.md`. Test counts
exclude removed selection-only behavior; they are not independent acceptance.

## Owner-authorized layout cutoff (separate pass)

- [x] 8. Shared standard ownership guard at all capture/processing/history/window boundaries before side effects; exact readonly flat metadata; no flat retry.
- [x] 9. Semantic RED/GREEN neighbours/durable writers/capture/start/runner/worker and standard lifecycle/source-free viewer; preserve unrelated assertions.
- [x] 10. Final full Swift suite, boundaries/OpenSpec, release/sign beta7/build43 and manifests/patches.
- [x] 11. Independent acceptance and owner GUI UAT for the narrowed standard-layout beta scope completed on beta.8/build44.

Cutoff author verification: final 250 Swift tests (192 Core/Application, 15 App,
26 Pipeline, 7 Vendor, 10 Assets), final release App/CLI/Worker, three compiled
GUI harnesses, boundaries/evaluated graph, strict specs, signed beta.7/build43,
deep strict/check-bundle and exact manifests/patches are recorded in external
`single-result-simplification/layout-cutoff/final-report.md`. Earlier beta.6
was CHANGES_REQUESTED. At that writer handoff these checks did not grant independent acceptance and
physical UAT was WAITING_UAT. No installation, migration or model inference was
performed during that authoring pass. Latest acceptance is recorded below.


## Latest acceptance — beta.8/build44 (2026-11-03)

The standard-layout revision received independent PASS. After the owner reported
beta7's missing baseline-speaker reference, an explicitly authorized narrow pass
restored speaker-safe correction and the complete final/baseline speaker registry.
That revision also received independent PASS (R1–R4 closed); post-review source,
patch and signed-bundle identity checks passed. The owner separately authorized
installation of beta.8/build44, with signature and all154 bundle entries verified.

Owner confirmation: recording/transcript works, audio is satisfactory, word and
speaker-name edits survive close/reopen, retry handles unsaved edits and exposes
one new current result, and cancellation permits a subsequent retry. Exact final
reply: «работает», «все эти сценарии работают». This closes the requested beta GUI
UAT; duration/device/backend details and extended permission/capture scenarios
were not independently measured. No model-parity or performance claim follows.

Acceptance, owner observations, source/bundle manifests, raw test logs and
installation proof remain in the coordinator run's
`completion-native-only/uat-baseline-speaker/`. The latest selected model-free
suite is235 tests, with final28 focused rerun;22 audio/model tests were not rerun.
All files and earlier evidence are preserved. No migration, commit, publication
or archive is part of this documentation closeout.
