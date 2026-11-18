## 1. Перенос и контракт

- [x] 1.1 Начать отдельную ветку/worktree от свежего master, прочитать AGENTS/CONTRIBUTING/ADR, сверить drift с baseline и текущим reminder; перенести только этот change.
- [x] 1.2 Запустить `openspec validate meeting-reminder-compact --type change --strict`; не отмечать implementation готовой по успешной валидации.
- [x] 1.3 Использовать geometry.md, фактические PNG и reference/index.html как единый эталон; демонавигацию/результат не переносить в приложение.

## 2. Геометрия и native presentation

- [x] 2.1 Реализовать outer 360 pt, border 1 pt внутри frame, padding 16 pt, radius 16 pt и отсутствие дополнительного halo; использовать fitting height вместо прежней fixed height.
- [x] 2.2 Установить точные fonts/leading/spacing, primary 8 pt radius и полную внутреннюю ширину, вторичную строку и recording separator/dot по geometry.md; сохранить short-recording warning.
- [x] 2.3 Реализовать chooser до 336 pt, строки/galочка/footer divider по эталону, constrained height/scroll без увеличения reminder; не добавлять поиск.
- [ ] 2.4 Сохранить переносы, clamp visibleFrame, обе темы, focus, keyboard и VoiceOver. Desktop controls не увеличивать автоматически до mobile 44 pt.

## 3. Regression на сохранённое поведение

- [x] 3.1 Выполнить существующие reminder/session/expectedSessionID tests. Если fitting/placement logic меняется, сначала добавить падающий тест для narrow/long-content frame, затем минимальную реализацию.
- [x] 3.2 Проверить normal stop-before-start, short cancellation, повторный accept, stale session/late callback, stop/start errors, modal/busy guards, skip/timeout/acknowledgement и независимость capsule.

## 4. Точная визуальная приёмка

- [ ] 4.1 Снять native PNG при том же logical viewport/scale/theme/data; измерить outer frame, content bounds, шрифты/leading, primary/secondary rectangles, stroke и радиусы, сравнить с reference.
- [x] 4.2 Представить численные отклонения и overlay/diff для обеих обычных веток и открытого chooser; отличия raster antialias не выдавать за нарушение, отличия геометрии не скрывать за ним.
- [ ] 4.3 Проверить длинное название, 12 встреч, малую высоту/узкий экран, 1×/2× и light/dark; проверить отсутствие дополнительной панели/halo и некорректного захвата focus.

## 5. Приёмка и завершение

- [x] 5.1 Выполнить профильные Swift tests, `swift build -c release`, `swift test`, module boundaries и прочие обязательные проверки AGENTS.md; описать реальные результаты.
- [ ] 5.2 Провести native UAT и независимое ревью UI diff, исправить подтверждённые замечания в пределах двух раундов; не объявлять source-only проверку visual PASS.
- [x] 5.3 Обновить CHANGELOG [Unreleased], получить приёмку перед архивированием. Установка/релиз требуют отдельного разрешения.

## Verification checkpoint

- 34 профильных теста прошли, включая выбор с клавиатуры, прокрутку, переключение темы и eligibility/acknowledgement. Независимое ревью кода прошло после одного раунда исправлений. Сборка release, module boundaries, finder self-test и OpenSpec validation прошли.
- Перед бетой `swift test --no-parallel` прошёл полностью: 619 Swift Testing и 14 XCTest. Ранее нестабильные тесты фокуса в Workspace и времени открытия длинного транскрипта в этом прогоне прошли. Проверки не ослабляли, причины прежних сбоев не установлены.
- Native comparison: 360×205 и 360×250 pt (высота выше эталона на 0.453125 pt), chooser 336×420 pt, primary 326×40 pt. Рендер при полном эталонном viewport, тень в оконном композиторе, клики сквозь тень, переключение фокуса между приложениями и физический VoiceOver отдельно не подтверждены.
- Владелец принял установленный build 87 с компактным напоминанием и разрешил выпуск в бету и закрытие SDD. Пункты 2.4, 4.1, 4.3 и 5.2 сохраняют статус неполной проверки. Изменение включено в CHANGELOG для `2.1.0-beta.2` (build 88).
