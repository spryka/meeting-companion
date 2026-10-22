"""Optional offline AEC3; originals are never modified and any failure falls back to them."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import wave


def pcm_info(path):
    with Path(path).open("rb", buffering=0) as file, wave.open(file) as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("AEC3 requires 16 kHz mono PCM16 WAVs")
        frames, offset = wav.getnframes(), file.tell()
        if not frames or offset + frames * 2 > os.fstat(file.fileno()).st_size:
            raise ValueError("Empty or truncated AEC3 input")
        return frames, offset


def cancel_echo(host, remote, on_progress, executable=None):
    host, remote = Path(host), Path(remote)
    frames, host_offset = pcm_info(host)
    other_frames, remote_offset = pcm_info(remote)
    if frames != other_frames:
        raise ValueError("AEC3 input timelines differ")
    if frames * 2 > 0xffffffff - 36:
        raise ValueError("AEC3 output exceeds PCM WAV size limit")
    # With an entirely silent reference, preserve the microphone bit for bit.
    with wave.open(str(remote)) as reference:
        while data := reference.readframes(16000 * 10):
            if any(data):
                break
        else:
            on_progress(frames, frames)
            return host
    executable = Path(executable) if executable else Path(__file__).with_name("aec") / "meeting-aec"
    if not os.access(executable, os.X_OK):
        raise FileNotFoundError("Bundled AEC3 processor is unavailable")
    output = host.with_suffix(".aec.wav")
    for source in (host, remote):
        if output.exists() and output.samefile(source):
            raise ValueError("AEC3 output aliases source audio")
    descriptor, temporary = tempfile.mkstemp(prefix=".aec-", suffix=".wav", dir=host.parent)
    try:
        with os.fdopen(descriptor, "wb", buffering=0) as destination:
            destination.write(struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + frames * 2,
                b"WAVE", b"fmt ", 16, 1, 1, 16000, 32000, 2, 16, b"data", frames * 2))
            with subprocess.Popen([str(executable), str(host), str(remote), str(host_offset),
                                   str(remote_offset), str(frames)], stdout=destination,
                                  stderr=subprocess.PIPE, text=True) as process:
                tail = ""
                try:
                    for line in process.stderr:
                        if line.startswith("AEC_PROGRESS "):
                            _, done, total = line.split()
                            if not 0 <= int(done) <= int(total) == frames:
                                raise ValueError("Invalid AEC3 progress")
                            on_progress(int(done), frames)
                        else:
                            tail = (tail + line)[-2000:]
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
                if process.wait() != 0:
                    raise RuntimeError(tail.strip() or "AEC3 processor failed")
        if pcm_info(temporary)[0] != frames or os.path.getsize(temporary) != 44 + frames * 2:
            raise ValueError("AEC3 output timeline is invalid")
        os.replace(temporary, output)
        return output
    finally:
        Path(temporary).unlink(missing_ok=True)
