#!/usr/bin/env python3
"""Check the same runtime and pinned models used by Meeting Companion."""
import argparse
import os
from pathlib import Path
import sys
from transcribe import load_gigaam_model, load_nemotron_model
from model_assets import model_path


def check(name, operation):
    print(f"Этап: {name}…", flush=True)
    try:
        operation()
        print(f"OK: {name}", flush=True)
        return True
    except Exception as error:
        print(f"ERROR: {name}: {error}", flush=True)
        return False


def scripts():
    folder = Path(__file__).parent
    for name in ("transcribe.py", "transcribe-recording.py", "model_assets.py", "audio_enhancement.py", "term_correction.py", "gigaam_mlx_backend.py", "gigaam_mlx_runtime.py", "gigaam-mlx-LICENSE", "run.sh"):
        path = folder / name
        if not path.is_file():
            raise FileNotFoundError(path)
        if name.endswith(".py"):
            compile(path.read_text(), str(path), "exec")
    if not os.access(folder / "run.sh", os.X_OK):
        raise PermissionError("run.sh is not executable")


def gigaam():
    import numpy as np
    model = load_gigaam_model()
    model.recognize(np.zeros(16000, dtype="float32"), sample_rate=16000)


def nemotron():
    import numpy as np
    import mlx.core as mx
    model = load_nemotron_model()
    result = model.generate(np.zeros(32000, dtype="float32"), sample_rate=16000)
    list(result.segments)
    mx.synchronize()


def vad():
    import numpy as np
    from audio_enhancement import load_vad, speech_windows
    speech_windows(np.zeros(16000, dtype='float32'), 16000, load_vad())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--availability", action="store_true")
    parser.add_argument("--parakeet", action="store_true")
    args = parser.parse_args()
    if not args.prepare or args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    names = ['gigaam', 'nemotron', 'vad'] + (['parakeet'] if args.parakeet else [])
    outcomes = [check("Файлы приложения", scripts)]
    for name in names:
        outcomes.append(check(name, lambda name=name: model_path(name, download=args.prepare)))
    if not args.availability:
        outcomes.extend([check("Распознавание речи", gigaam), check("Разделение голосов", nemotron)])
        outcomes.append(check("Детектор речи", vad))
        if args.parakeet:
            def parakeet():
                import numpy as np
                import mlx.core as mx
                from audio_enhancement import load_parakeet_model, parakeet_words
                result = load_parakeet_model().generate(mx.array(np.zeros(16000, dtype='float32')), dtype=mx.float16)
                parakeet_words(result, 0, 1, 0, 1)
                mx.synchronize()
            outcomes.append(check("Parakeet / MLX", parakeet))
    return 0 if all(outcomes) else 1


if __name__ == "__main__":
    sys.exit(main())
