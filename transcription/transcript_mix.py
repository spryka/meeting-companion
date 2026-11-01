"""Prepare the immutable playback mix for a transcript version."""

from pathlib import Path
import os
import subprocess
import tempfile
import wave

import numpy as np


_SAMPLE_RATE = 16000
_BLOCK_FRAMES = 65536


def _validate_wave(audio: wave.Wave_read) -> int:
    if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(),
            audio.getcomptype()) != (1, 2, _SAMPLE_RATE, "NONE"):
        raise ValueError("Playback sources must be PCM16 mono 16 kHz WAV")
    frames = audio.getnframes()
    if frames <= 0:
        raise ValueError("Playback audio is empty")
    return frames


def _read_frames(audio: wave.Wave_read, count: int) -> bytes:
    data = audio.readframes(count)
    if len(data) != count * 2:
        raise ValueError("Playback WAV is truncated")
    return data


def prepare_mix(host: Path, remote: Path, destination: Path) -> None:
    """Mix the supplied recognition sources without changing or replacing files.

    The caller chooses the actual recognition microphone (AEC or original).
    Audio and validation are streamed; only owned temporary files are removed.
    A ready mix is published exclusively after a complete decode check.
    """
    host, remote, destination = Path(host), Path(remote), Path(destination)
    if destination.resolve() in (host.resolve(), remote.resolve()):
        raise ValueError("Playback destination must not be a source")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)

    temporary_paths = []

    def temporary(suffix):
        descriptor, name = tempfile.mkstemp(prefix=".transcript-mix-", suffix=suffix,
                                             dir=destination.parent)
        os.close(descriptor)
        path = Path(name)
        temporary_paths.append(path)
        return path

    try:
        with wave.open(str(host), "rb") as microphone, wave.open(str(remote), "rb") as system:
            frames = _validate_wave(microphone)
            if _validate_wave(system) != frames:
                raise ValueError("Playback sources must have identical durations")
            mixed = temporary(".wav")
            with wave.open(str(mixed), "wb") as output:
                output.setparams((1, 2, _SAMPLE_RATE, 0, "NONE", "not compressed"))
                for offset in range(0, frames, _BLOCK_FRAMES):
                    count = min(_BLOCK_FRAMES, frames - offset)
                    left = np.frombuffer(_read_frames(microphone, count), dtype="<i2").astype(np.int32)
                    right = np.frombuffer(_read_frames(system, count), dtype="<i2").astype(np.int32)
                    # Widen before summing so coincident full-scale audio cannot wrap.
                    output.writeframesraw(((left + right) // 2).astype("<i2").tobytes())

        encoded = temporary(".m4a")
        subprocess.run(["/usr/bin/afconvert", str(mixed), str(encoded),
                        "-f", "m4af", "-d", "aac", "-b", "32000", "-q", "127"],
                       check=True, capture_output=True)
        if encoded.stat().st_size == 0:
            raise ValueError("Playback encoder produced an empty file")
        decoded = temporary(".wav")
        # Core Audio honors the M4A packet table's priming/remainder metadata.
        # Do not count AAC encoder delay as silence on the source timeline.
        subprocess.run(["/usr/bin/afconvert", str(encoded), str(decoded),
                        "-f", "WAVE", "-d", "LEI16@16000"],
                       check=True, capture_output=True)
        with wave.open(str(decoded), "rb") as verification:
            decoded_frames = _validate_wave(verification)
            # AAC-LC packets contain 1024 samples. Some Core Audio versions
            # retain the last packet's padding; never allow missing source frames.
            if not frames <= decoded_frames <= frames + 1023:
                raise ValueError("Playback mix duration does not match its sources")
            for offset in range(0, decoded_frames, _BLOCK_FRAMES):
                _read_frames(verification, min(_BLOCK_FRAMES, decoded_frames - offset))
        # Same-directory hard link publishes atomically without overwriting a
        # concurrently created destination. The temporary name is removed below.
        os.link(encoded, destination)
    except (EOFError, wave.Error) as error:
        raise ValueError("Playback WAV is invalid or truncated") from error
    finally:
        for path in temporary_paths:
            path.unlink(missing_ok=True)
