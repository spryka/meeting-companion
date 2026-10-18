"""Pinned model artifacts shared by preparation, diagnostics and inference."""
import hashlib
import os
from pathlib import Path
import sys

MODELS = {
    'gigaam': dict(repo='istupakov/gigaam-v3-onnx', revision='322c3b29492673eb7d0b434bfa9dfb8653e34d02',
        files=['config.json', 'v3_e2e_rnnt_encoder.onnx', 'v3_e2e_rnnt_decoder.onnx',
               'v3_e2e_rnnt_joint.onnx', 'v3_e2e_rnnt_vocab.txt']),
    'nemotron': dict(repo='mlx-community/Nemotron-3-Diarization', revision='59ed2dbfc1346dcea9d423c71306a3a2499c568f',
        files=['config.json', 'model.safetensors']),
    'vad': dict(repo='istupakov/silero-vad-onnx', revision='8b14476858ef240c50b3884bb38cc67290c1cc70', files=['silero_vad.onnx'],
        sha256='1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3'),
    'parakeet': dict(repo='memoravox/parakeet-tdt-0.6b-v3-gguf', revision='cb1f2b1b2f7dd49ca1016610cfa58e1e75350729',
        files=['parakeet-tdt-0.6b-v3-Q8_0.gguf'],
        sha256='5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7'),
}


class ModelUnavailable(RuntimeError):
    pass


def validate_model(name, directory):
    spec = MODELS[name]
    for filename in spec['files']:
        path = directory / filename
        if not path.is_file() or not path.stat().st_size:
            raise ModelUnavailable(f'{name}: отсутствует {filename}. Скачайте модели в настройках.')
    if spec.get('sha256'):
        with (directory / spec['files'][0]).open('rb') as handle:
            digest = hashlib.file_digest(handle, 'sha256').hexdigest()
        if digest != spec['sha256']:
            raise ModelUnavailable(f'{name}: повреждён файл модели. Повторите скачивание в настройках.')
    return directory


def model_path(name, *, download=False):
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError
    spec = MODELS[name]
    options = dict(revision=spec['revision'], allow_patterns=spec['files'])
    corrupt = False
    try:
        directory = Path(snapshot_download(spec['repo'], local_files_only=True, **options))
        try:
            return validate_model(name, directory)
        except ModelUnavailable:
            corrupt = True
            if not download:
                raise
    except LocalEntryNotFoundError as error:
        if not download or os.environ.get('HF_HUB_OFFLINE') == '1':
            raise ModelUnavailable(f'{name}: модели нет в кэше. Скачайте её в настройках.') from error
    if os.environ.get('HF_HUB_OFFLINE') == '1':
        raise ModelUnavailable(f'{name}: модель недоступна офлайн.')
    print(f'{name}: скачивание модели…', file=sys.stderr, flush=True)
    directory = Path(snapshot_download(spec['repo'], force_download=corrupt, **options))
    return validate_model(name, directory)
