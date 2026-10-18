"""Silero gates whole ASR windows; Parakeet supplies optional term alternatives."""
import math
from pathlib import Path

from model_assets import MODELS, model_path


def windows(sample_count, rate=16000):
    for start in range(0, sample_count, 24 * rate):
        end = min(start + 25 * rate, sample_count)
        yield start, end
        if end == sample_count:
            break


def load_vad():
    import onnx_asr
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    return onnx_asr.load_vad('silero', path=model_path('vad'), sess_options=options,
                             providers=['CPUExecutionProvider'])


def speech_windows(samples, rate, vad):
    import numpy as np
    if rate != 16000 or samples.ndim != 1 or not np.isfinite(samples).all():
        raise ValueError('VAD requires finite 16 kHz mono samples')
    grid = list(windows(len(samples), rate))
    if not grid:
        return []
    # Detection only: ASR and saved audio always receive the original samples.
    boosted = np.clip(samples * np.float32(10**(6/20)), -1, 1)
    intervals = list(next(vad.segment_batch(boosted[None, :], np.array([len(samples)], dtype=np.int64), rate,
        threshold=.5, min_speech_duration_ms=250, min_silence_duration_ms=250,
        speech_pad_ms=150, max_speech_duration_s=20)))
    if any(not (0 <= a < b <= len(samples)) for a, b in intervals):
        raise ValueError('Invalid VAD intervals')
    return [any(a < end and b > start for a, b in intervals) for start, end in grid]


def run_parakeet(audio_path: Path, keep, on_progress=None):
    import transcribe_cpp as tc
    from transcribe import load_audio
    tc.set_log_callback(None)
    samples, rate = load_audio(audio_path)
    grid = list(windows(len(samples), rate))
    if len(keep) != len(grid):
        raise ValueError('Parakeet window mask does not match audio')
    words = []
    if on_progress:
        on_progress('parakeet', 0, len(grid))
    with tc.Model(model_path('parakeet') / MODELS['parakeet']['files'][0], backend='metal') as model:
        with tc.Session(model, n_threads=4) as session:
            for index, ((start, end), speech) in enumerate(zip(grid, keep), 1):
                if speech:
                    result = session.run(samples[start:end], timestamps='word')
                    if result.text.strip() and not result.words:
                        raise RuntimeError('Parakeet returned no word timestamps')
                    lower = 0 if start == 0 else start / rate + .5
                    upper = end / rate + .1 if end == len(samples) else start / rate + 24.5
                    for word in result.words:
                        at, until = start/rate + word.t0_ms/1000, start/rate + word.t1_ms/1000
                        if not (math.isfinite(at) and math.isfinite(until)
                                and start/rate <= at <= until <= end/rate + .15
                                and isinstance(word.text, str)):
                            raise RuntimeError('Parakeet returned invalid word timestamps')
                        if lower <= at < upper:
                            words.append(dict(start=at, end=min(until, end/rate), text=word.text))
                if on_progress:
                    on_progress('parakeet', index, len(grid))
    return words
