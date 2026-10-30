"""Timestamped adapter for the bundled al-bo GigaAM E2E RNNT runtime."""
import os
from types import SimpleNamespace


def decode_with_frames(model, encoded, seq_len):
    # Adapted from misteral/GigaAM b258565; MIT, see gigaam-mlx-LICENSE.
    import mlx.core as mx
    tokens, frames = [], []
    state = last_label = None
    for t in range(seq_len):
        f = encoded[t:t + 1, :].reshape(1, 1, -1)
        for _ in range(model.cfg.rnnt_max_symbols):
            g, new_state = model.head.decoder.predict(last_label, state, batch_size=1)
            logits = model.head.joint(f, g)
            token = int(mx.argmax(logits[0, 0, 0, :]).item())
            if token == len(model.cfg.vocabulary):
                break
            tokens.append(token)
            frames.append(t)
            state, last_label = new_state, token
    return tokens, frames


class TimestampedGigaAM:
    def __init__(self, model):
        self.model = model

    def recognize(self, samples, *, sample_rate):
        import mlx.core as mx
        import numpy as np
        cfg = self.model.cfg
        samples = np.asarray(samples, dtype=np.float32)
        if sample_rate != cfg.sample_rate or samples.ndim != 1 or not np.isfinite(samples).all():
            raise ValueError("GigaAM MLX requires finite 16 kHz mono audio")
        if len(samples) == 0:
            return SimpleNamespace(text="", tokens=[], timestamps=[])
        if len(samples) < cfg.win_length:
            samples = np.pad(samples, (0, cfg.win_length - len(samples)))
        features, lengths = self.model._compute_features(mx.array(samples))
        encoded, lengths = self.model(features, lengths)
        mx.eval(encoded, lengths)
        ids, frames = decode_with_frames(self.model, encoded[0], int(lengths[0]))
        seconds_per_frame = cfg.hop_length / cfg.sample_rate * cfg.subsampling_factor
        return SimpleNamespace(text=self.model._decode_tokens(ids),
            tokens=[cfg.vocabulary[i] for i in ids],
            timestamps=[frame * seconds_per_frame for frame in frames])


def load_model():
    from gigaam_mlx_runtime import load_model as load_mlx
    from model_assets import model_path
    path = model_path('gigaam', download=os.environ.get('HF_HUB_OFFLINE') != '1')
    return TimestampedGigaAM(load_mlx(str(path)))
