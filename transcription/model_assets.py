"""Pinned model artifacts shared by preparation, diagnostics and inference."""
import hashlib
import os
from pathlib import Path
import sys

MODELS = {
    'gigaam': dict(repo='al-bo/gigaam-v3-e2e-rnnt-mlx', revision='9488b39159c6d30f0fbaef1e41459f1e078daf30',
        files=['model.safetensors', 'config.json', 'tokenizer.model']),
    'nemotron': dict(repo='mlx-community/Nemotron-3-Diarization', revision='59ed2dbfc1346dcea9d423c71306a3a2499c568f',
        files=['config.json', 'model.safetensors']),
    'vad': dict(repo='mlx-community/silero-vad-v6', revision='2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06',
        files=['model.safetensors', 'config.json'],
        sha256='65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff'),
    'parakeet': dict(repo='craquehouse/parakeet-tdt-0.6b-v3-mlx-8bit', revision='29d291a62b4013d74a24d79fca00883b717d988a',
        files=['model.safetensors', 'config.json', 'tokenizer.model', 'tokenizer.vocab', 'vocab.txt'],
        sha256='3e9a25e0f1c4cd866868e271601407b5a5c187ac1d4f7324a4867120775204eb'),
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
