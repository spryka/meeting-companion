#!/usr/bin/env python3
"""Offline experiment only: process a copy of synchronized raw microphone/system WAVs."""
import argparse
import hashlib
from pathlib import Path
import tempfile
import wave

RATE = 16000
FRAME_BYTES = 320  # WebRTC processes 10 ms of mono PCM16.


def process(host: Path, remote: Path, output: Path, delay_ms: int = 0):
    from aec_audio_processing import AudioProcessor

    if not 0 <= delay_ms <= 500:
        raise ValueError("delay-ms must be between 0 and 500")
    with wave.open(str(host), "rb") as microphone, wave.open(str(remote), "rb") as reference:
        for source in (microphone, reference):
            if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (1, 2, RATE, "NONE"):
                raise ValueError("Both inputs must be synchronized 16 kHz mono PCM16 WAVs")
        frames = microphone.getnframes()
        if frames == 0 or frames != reference.getnframes():
            raise ValueError("Inputs must be nonempty and have the same timeline length")
        ap = AudioProcessor(enable_aec=True, enable_ns=False, enable_agc=False, enable_vad=False)
        ap.set_stream_format(RATE, 1)
        ap.set_reverse_stream_format(RATE, 1)
        if not ap.aec_enabled() or ap.ns_enabled() or ap.agc_enabled():
            raise RuntimeError("AEC-only configuration did not take effect")
        # Exclusive creation protects originals and previous experiment results, including symlinks.
        with output.open("xb") as destination:
            try:
                with wave.open(destination, "wb") as result:
                    result.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
                    for start in range(0, frames, 160):
                        count = min(160, frames - start) * 2
                        mic = microphone.readframes(160)
                        far = reference.readframes(160)
                        if len(mic) != count or len(far) != count:
                            raise ValueError("Truncated input WAV")
                        ap.process_reverse_stream(far.ljust(FRAME_BYTES, b"\0"))
                        ap.set_stream_delay(delay_ms)
                        clean = ap.process_stream(mic.ljust(FRAME_BYTES, b"\0"))
                        if len(clean) != FRAME_BYTES:
                            raise RuntimeError("AEC returned an invalid frame")
                        result.writeframesraw(clean[:count])
            except BaseException:
                output.unlink()  # Only the file just created by this process.
                raise
    return frames


def self_check():
    import numpy as np

    rng = np.random.default_rng(1234)
    far = rng.normal(0, 0.1, RATE * 20 + 37)
    # Synthetic linear loudspeaker path with two delayed reflections.
    mic = np.zeros_like(far)
    mic[160:] += 0.55 * far[:-160]
    mic[240:] += 0.2 * far[:-240]
    with tempfile.TemporaryDirectory(prefix="meeting-webrtc-check-") as directory:
        root = Path(directory)
        def write(name, samples):
            path = root / name
            with wave.open(str(path), "wb") as wav:
                wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
                wav.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
            return path
        def read(path):
            with wave.open(str(path), "rb") as wav:
                return np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype(float) / 32767
        host, remote = write("host.wav", mic), write("remote.wav", far)
        original = [hashlib.sha256(p.read_bytes()).digest() for p in (host, remote)]
        output = root / "clean.wav"
        assert process(host, remote, output) == len(mic)
        clean = read(output)
        assert len(clean) == len(mic), "Tail padding must not extend the recording"
        attenuation = 10 * np.log10(np.mean(mic[-RATE * 5:] ** 2) / max(np.mean(clean[-RATE * 5:] ** 2), 1e-12))
        assert attenuation > 10, f"Synthetic echo was not suppressed: {attenuation:.1f} dB"
        result_bytes = output.read_bytes()
        try:
            process(host, remote, output)
            raise AssertionError("Existing result overwritten")
        except FileExistsError:
            pass
        assert output.read_bytes() == result_bytes
        try:
            process(host, remote, host)
            raise AssertionError("Source overwritten")
        except FileExistsError:
            pass
        assert original == [hashlib.sha256(p.read_bytes()).digest() for p in (host, remote)]
        # Speech-like near-end signal with silent reference must remain audible.
        time = np.arange(len(far)) / RATE
        voice = 0.1 * np.sin(2 * np.pi * 230 * time) + 0.05 * np.sin(2 * np.pi * 460 * time)
        near, silent = write("near.wav", voice), write("silence.wav", np.zeros_like(far))
        near_result = root / "near-clean.wav"
        process(near, silent, near_result)
        gain = 10 * np.log10(np.mean(read(near_result)[-RATE:] ** 2) / np.mean(voice[-RATE:] ** 2))
        assert abs(gain) < 3, f"Near-end level changed too much: {gain:.1f} dB"
        short = write("short.wav", far[:100])
        try:
            process(host, short, root / "invalid.wav")
            raise AssertionError("Mismatched timelines accepted")
        except ValueError:
            pass
        assert not (root / "invalid.wav").exists()
        print(f"AEC3 synthetic check: echo attenuation {attenuation:.1f} dB; near-end gain {gain:.1f} dB; timeline and source protection passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="Synthetic checks only; never captures hardware")
    run = commands.add_parser("process", help="Write a new cleaned microphone WAV")
    run.add_argument("host", type=Path)
    run.add_argument("remote", type=Path)
    run.add_argument("output", type=Path)
    run.add_argument("--delay-ms", type=int, default=0)
    args = parser.parse_args()
    if args.command == "check":
        self_check()
    else:
        try:
            frames = process(args.host, args.remote, args.output, args.delay_ms)
        except (OSError, ValueError, RuntimeError, wave.Error) as error:
            parser.exit(1, f"AEC experiment failed: {error}\n")
        print(f"AEC-only copy saved: {args.output}; {frames / RATE:.3f} s")


if __name__ == "__main__":
    main()
