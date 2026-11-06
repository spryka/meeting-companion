# Проверка GPU при захвате звука

`scripts/probe-capture.swift` сравнивает три отдельных тракта без интерфейса,
записи файлов, конвертации и распознавания:

- `avcapture`: выбранный микрофон через AVCaptureSession, как у Core Audio Tap в приложении.
- `tap`: только системный Core Audio Tap с приватным агрегатным устройством.
- `hal`: только выбранный микрофон через AudioDeviceCreateIOProcIDWithBlock.

Стенд не меняет системный микрофон, выход, частоту устройства или Mic Mode.
Новый процесс имеет собственную настройку Mic Mode: для AVCapture сравнить
и "Стандартный", и "Изоляцию голоса", записывая фактически выбранный режим.
Значения MicMode в выводе: 0 = standard, 1 = wideSpectrum, 2 = voiceIsolation.
HAL не является гарантированным обходом системного DSP: это проверяемая гипотеза.

## Подготовка

Скомпилировать на Apple Silicon, macOS 15+, из корня репозитория:

```sh
PROBE_APP='/tmp/meeting-capture-probe-20261023/Capture Probe.app'
mkdir -p "$PROBE_APP/Contents/MacOS"
python3 - "$PROBE_APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({
        'CFBundleIdentifier': 'local.meeting-companion.capture-probe',
        'CFBundleName': 'Capture Probe', 'CFBundleExecutable': 'CaptureProbe',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True,
        'NSMicrophoneUsageDescription': 'Сравнение захвата без сохранения звука.',
        'NSAudioCaptureUsageDescription': 'Проверка системного звука без сохранения.',
    }, file)
PY
swiftc -parse-as-library -O -target arm64-apple-macos15.0 scripts/probe-capture.swift -o "$PROBE_APP/Contents/MacOS/CaptureProbe"
codesign --force --sign - "$PROBE_APP"
"$PROBE_APP/Contents/MacOS/CaptureProbe" --self-check
```

## Прогон

Проводить вне звонка, записи и фонового распознавания. Приложение MC не должно
держать проверку звука или индикаторы микрофона; надёжнее штатно выйти из него.
Остальную нагрузку, видимость btop и звук воспроизведения держать одинаковыми.
Первый запуск может запросить разрешения; время показа запросов не сравнивать.

Сначала `--list`, затем выбрать UID микрофона ноутбука. Запускать по одному:
`avcapture 30 UID`, `tap 30 UID`, `hal 30 UID`. Между прогонами выдержать
15 секунд без захвата для базового уровня GPU. Звуковые файлы не создаются.

Каждый режим сам останавливается через 30 секунд и сообщает число буферов;
нулевое число означает невалидный прогон, а не успешное снижение нагрузки.
Наблюдать устойчивую нагрузку GPU и возврат к исходному уровню, не только пики.
График btop показывает суммарный GPU; сторонняя нагрузка остаётся смешивающим фактором.
Снижение GPU в минимальном стенде ещё не доказывает эффективность полноценной
записи: после локализации причины нужна повторная проверка конвертации и сохранения.
