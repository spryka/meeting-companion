"""Silero gates whole ASR windows; Parakeet supplies optional term alternatives."""
import math
from numbers import Integral, Real
from pathlib import Path

from model_assets import model_path


def windows(sample_count, rate=16000):
    for start in range(0, sample_count, 24 * rate):
        end = min(start + 25 * rate, sample_count)
        yield start, end
        if end == sample_count:
            break


def load_vad():
    import json
    import mlx.core as mx
    from mlx_audio.vad.models.silero_vad.silero_vad import Model
    from mlx_audio.vad.models.silero_vad.config import ModelConfig
    path = model_path('vad')
    model = Model(ModelConfig.from_dict(json.loads((path / 'config.json').read_text())))
    # The pinned v6 checkpoint has only 16 kHz weights; exclude the unused 8 kHz branch.
    model.vad_8k = None
    model.load_weights(str(path / 'model.safetensors'), strict=True)
    mx.eval(model.parameters())
    return model


def speech_windows(samples, rate, vad):
    import numpy as np
    if rate != 16000 or samples.ndim != 1 or not np.isfinite(samples).all():
        raise ValueError('VAD requires finite 16 kHz mono samples')
    grid = list(windows(len(samples), rate))
    if not grid:
        return []
    # Detection only: ASR and saved audio always receive the original samples.
    boosted = np.clip(samples * np.float32(10**(6/20)), -1, 1)
    intervals = vad.get_speech_timestamps(boosted, sample_rate=rate,
        threshold=.5, min_speech_duration_ms=250, min_silence_duration_ms=250,
        speech_pad_ms=150)
    if any(not (isinstance(row['start'], Integral) and isinstance(row['end'], Integral)
                and 0 <= row['start'] < row['end'] <= len(samples)) for row in intervals):
        raise ValueError('Invalid VAD intervals')
    return [any(row['start'] < end and row['end'] > start for row in intervals) for start, end in grid]


def load_parakeet_model():
    from mlx_audio.stt.utils import load
    return load(model_path('parakeet'), strict=True)


def parakeet_words(result, start, end, lower, upper):
    words = []
    previous = -1
    for sentence in result.sentences:
        for token in sentence.tokens:
            if not (isinstance(token.text, str) and isinstance(token.start, Real)
                    and isinstance(token.end, Real) and math.isfinite(token.start)
                    and math.isfinite(token.end) and previous <= token.start
                    and 0 <= token.start <= end - start
                    and token.start <= token.end <= end - start + .15):
                raise RuntimeError('Parakeet returned invalid token timestamps')
            previous = token.start
            if not words or token.text.startswith((' ', '▁')):
                words.append(dict(start=start + token.start, end=start + token.start, text=''))
            words[-1]['text'] += token.text.replace('▁', ' ')
            words[-1]['end'] = min(end, max(words[-1]['end'], start + token.end))
    if result.text.strip() and not any(word['text'].strip() for word in words):
        raise RuntimeError('Parakeet returned no word timestamps')
    return [{**word, 'text': word['text'].strip()} for word in words
            if lower <= word['start'] < upper and word['text'].strip()]


def run_parakeet(audio_path: Path, keep, on_progress=None):
    import mlx.core as mx
    from transcribe import load_audio
    samples, rate = load_audio(audio_path)
    grid = list(windows(len(samples), rate))
    if len(keep) != len(grid):
        raise ValueError('Parakeet window mask does not match audio')
    words = []
    if on_progress:
        on_progress('parakeet', 0, len(grid))
    model = load_parakeet_model()
    for index, ((start, end), speech) in enumerate(zip(grid, keep), 1):
        if speech:
            result = model.generate(mx.array(samples[start:end]), dtype=mx.float16)
            lower = 0 if start == 0 else start / rate + .5
            upper = end / rate + .1 if end == len(samples) else start / rate + 24.5
            words.extend(parakeet_words(result, start / rate, end / rate, lower, upper))
        if on_progress:
            on_progress('parakeet', index, len(grid))
    return words
