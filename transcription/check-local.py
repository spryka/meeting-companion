#!/usr/bin/env python3
"""Check the same runtime and pinned models used by Meeting Companion."""
import argparse
import os
from pathlib import Path
import sys
from transcribe import load_gigaam_model, load_nemotron_model


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
    for name in ("transcribe.py", "transcribe-recording.py", "run.sh"):
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
    args = parser.parse_args()
    if not args.prepare or args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    outcomes = [check("Файлы приложения", scripts),
                check("Распознавание речи", gigaam),
                check("Разделение голосов", nemotron)]
    return 0 if all(outcomes) else 1


if __name__ == "__main__":
    sys.exit(main())
