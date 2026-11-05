# Handoff source and adaptation

## Provenance

Полный immutable external Open Design handoff, project 1e4045b3-620a-4ddf-b7ba-dfde9d3567a6, release-stable/sdd-handoff. Передача подготовлена 2026-11-01, transcript corrections обновлены 2026-11-03. Повторное чтение/проверка: 2026-11-04. Точный локальный root и raw logs сохранены во внешнем writer report, без машинных путей в репозитории.

Manifest SHA-256: b4a15fd2083337729c4a294ae8a08424eaa076ccf40d0865c4853a73e36ce79e. Все 14 относительных путей, размеры и SHA-256 проверены, missing/extra нет; изменений относительно прежнего b4a15fd… наблюдения нет. HTML прочитан полностью, строки 1–547 (последняя без newline), без открытия пользовательских окон. External package не редактировался. reference/index.html и artifact.json скопированы побайтово, не runtime implementation.

## Root README summary

Исходный README требует читать repo rules/ADRs/specs/callers, не перезаписывать существующий change, перепроверить свободный номер ADR и начать после document/architecture review. HTML выбран пользователем как visual direction, обычный click открывает меню. Дополнение 2026-11-03 задаёт text edits, одну реплику или same original source/voice отсюда до конца, preview/Cancel и saved undo exclusion; календарные имена только demo, manual input всегда. Пакет не утверждает Swift implementation/build/test/UAT.

## Adaptation to final master

Baseline 1e479aa8ed69f82222c82119ff106b1c3aa28002; native closure прочитан. Proposal/spec/design/context/adr/tasks/matrix адаптированы согласованно: current-only по ADR0004, canonical ownership/flat read-only по ADR0005; Python reset заменён native-models/runtime; draft modal сохраняет admission/CAS/teardown, separate-window UX удаляется. Proposed handoff ADR0002 перенумерован в новый root ADR0006; accepted ADR не переписаны. Rename исследован и описан как optional displayTitle в existing metadata boundary, без path migration. Runtime evidence/implementation не заявлены.

При расхождении prose/JS оригинального HTML с обновлёнными specs действует обновлённый contract. В частности demo clock/waveform/timer/network/permissions/storage и старый Python reset text не становятся требованиями реализации. Источник остаётся точным для независимой проверки.

## Source inventory

| External relative path | Bytes | SHA-256 |
|---|---:|---|
| README.md | 5171 | 22f91e4b07f611577d58f552134a8868d73aab51232c0aaa7a1586d3c561ec49 |
| adr/0002-independent-workspace-and-recording-overlay.md | 2862 | 5cad113de542570f17197dcb10d4d0ec2d0f240a14c44be45ff13870bfb947de |
| openspec/changes/refresh-macos-interface/adr.md | 2174 | 791173614c691fdb0b966d9361695a43321715efdd02a4c443d3dcccfd2315db |
| openspec/changes/refresh-macos-interface/context.md | 10199 | 4eb5614a14c58d8e0746dc03e109e7e4e0beba7e28684e6bed80893ade93502b |
| openspec/changes/refresh-macos-interface/design.md | 20388 | 860b5f8ebff333a395130929cdebfe74eba15d4e34a560d797f7e539a4e587ed |
| openspec/changes/refresh-macos-interface/proposal.md | 5032 | 54e7468549a32b6d7ad1b11df78b8dca89eecbe71b7c29b73ca7ccd5f4c47b42 |
| openspec/changes/refresh-macos-interface/reference/index.html | 91354 | 72899a6f451b68665f5e330580dd43e23010f80ebc5a06c8ee45d4b9ef7d28c3 |
| openspec/changes/refresh-macos-interface/reference/index.html.artifact.json | 463 | 9608313ab6a8e2af3ed21b62c9c0d9a32a7c13b4f67aab55fc618c29bf9e39bb |
| openspec/changes/refresh-macos-interface/requirements-matrix.md | 6850 | 48a6a7857c2920d254d1d341e8ca313999d53a3f3fb82fbfd1a47fa1811049be |
| openspec/changes/refresh-macos-interface/specs/desktop-workspace/spec.md | 15803 | 9f5d43323bb192fc349497d047f91ec71c7bd26924bc4fb8f09910c8a24bb653 |
| openspec/changes/refresh-macos-interface/specs/macos-status-menu/spec.md | 3620 | a4fca68b1fcc735e462c8310a8f705612353fbf256b826c99b7646d5aef35db5 |
| openspec/changes/refresh-macos-interface/specs/preferences-navigation/spec.md | 7259 | 1e4338eb7a8a4ca2c30dec9c3ee21e0b53dc6c41c8cd81858a3e7b499db0a6bf |
| openspec/changes/refresh-macos-interface/specs/recording-overlay/spec.md | 8521 | 3cd2b7c1116a67cc31d23221344197db8b7cfc1ede9345943df36f22e0a5ae95 |
| openspec/changes/refresh-macos-interface/tasks.md | 14417 | a3e5cc057201348b2f2d92a19cc7376518d614e7da1a43192f4919a7b8a01c42 |
