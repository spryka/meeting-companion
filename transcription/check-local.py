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
    for name in ("transcribe.py", "transcribe-recording.py", "model_assets.py", "audio_enhancement.py", "term_correction.py", "run.sh"):
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
        from audio_enhancement import load_vad
        outcomes.append(check("Детектор речи", load_vad))
        if args.parakeet:
            def parakeet():
                import numpy as np
                import transcribe_cpp as tc
                from model_assets import MODELS
                tc.set_log_callback(None)
                with tc.Model(model_path('parakeet') / MODELS['parakeet']['files'][0], backend='metal') as model:
                    with tc.Session(model, n_threads=4) as session:
                        session.run(np.zeros(16000, dtype='float32'), timestamps='word')
            outcomes.append(check("Parakeet / Metal", parakeet))
    return 0 if all(outcomes) else 1


if __name__ == "__main__":
    sys.exit(main())
