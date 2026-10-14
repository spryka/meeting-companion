#!/usr/bin/env python3
"""
Meeting Companion transcription: Russian speech and speaker separation.
Uses GigaAM CPU for transcription and Nemotron GPU for diarization.
Offline mode requires cached dependencies and models.
"""

import argparse
from bisect import bisect_right
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path


def load_audio(audio_path: Path):
    import soundfile as sf
    info = sf.info(audio_path)
    if audio_path.suffix.lower() != ".wav" or info.samplerate != 16000 or info.channels != 1:
        raise ValueError("Meeting Companion requires 16 kHz mono WAV source audio")
    return sf.read(audio_path, dtype="float32")


def format_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    if hours > 0:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def format_duration(seconds: float) -> str:
    if seconds >= 60:
        mins = int(seconds // 60)
        secs = int(seconds % 60)
        return f"{mins}m {secs}s"
    return f"{seconds:.1f}s"


def load_nemotron_model():
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError
    from mlx_audio.vad import load

    repo = "mlx-community/Nemotron-3-Diarization"
    revision = "59ed2dbfc1346dcea9d423c71306a3a2499c568f"
    options = dict(revision=revision, allow_patterns=["config.json", "model.safetensors"])
    try:
        model_path = snapshot_download(repo, local_files_only=True, **options)
    except LocalEntryNotFoundError:
        if os.environ.get("HF_HUB_OFFLINE") == "1":
            raise
        print("Nemotron (голоса): скачивание модели…", file=sys.stderr, flush=True)
        model_path = snapshot_download(repo, **options)

    print("Nemotron: загрузка в память…", file=sys.stderr, flush=True)
    model = load(Path(model_path), strict=True)
    model.set_streaming_config("offline")
    return model


def run_nemotron_diarization(audio_path: Path):
    """Nemotron on MLX GPU with the offline preset."""
    print("Running Nemotron diarization (MLX GPU, offline preset)...", file=sys.stderr, flush=True)
    started = time.monotonic()
    model = load_nemotron_model()
    samples, sr = load_audio(audio_path)
    result = model.generate(samples, sample_rate=sr)
    segments = list(result.segments)
    duration = len(samples) / sr
    if not segments:
        raise RuntimeError("Nemotron returned no speech intervals; review audio")
    for seg in segments:
        if not (math.isfinite(seg.start) and math.isfinite(seg.end)
                and 0 <= seg.start < seg.end <= duration + 1
                and isinstance(seg.speaker, int) and 0 <= seg.speaker < 8):
            raise RuntimeError("Nemotron returned an invalid speech interval")
    count = len({seg.speaker for seg in segments})
    print(f"Nemotron finished: {count} speakers, {len(segments)} intervals in "
          f"{format_duration(time.monotonic() - started)}", file=sys.stderr, flush=True)
    return segments, count


def gigaam_words(result, start: float, end: float, lower: float, upper: float):
    """Join RNNT subword tokens, using the midpoint of chunk overlap as its seam."""
    tokens, times = result.tokens, result.timestamps
    if tokens is None or times is None or len(tokens) != len(times):
        raise RuntimeError("GigaAM returned invalid token timestamps")
    words = []
    for token, timestamp in zip(tokens, times):
        if not isinstance(token, str) or not math.isfinite(timestamp) or not 0 <= timestamp <= end - start:
            raise RuntimeError("GigaAM returned invalid token timestamps")
        at = start + timestamp
        if words and at < words[-1]["start"]:
            raise RuntimeError("GigaAM returned unordered token timestamps")
        if not words or token.startswith(("▁", " ")):
            words.append({"start": at, "end": min(end, at + 0.1), "text": ""})
        words[-1]["text"] += token.replace("▁", " ")
        words[-1]["end"] = min(end, at + 0.1)
    return [{**word, "text": word["text"].strip()} for word in words
            if lower <= word["start"] < upper and word["text"].strip()]


def load_gigaam_model():
    import onnx_asr
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    options = dict(revision="322c3b29492673eb7d0b434bfa9dfb8653e34d02",
                   allow_patterns=["config.json", "v3_e2e_rnnt_encoder.onnx", "v3_e2e_rnnt_decoder.onnx",
                                   "v3_e2e_rnnt_joint.onnx", "v3_e2e_rnnt_vocab.txt"])
    try:
        path = snapshot_download("istupakov/gigaam-v3-onnx", local_files_only=True, **options)
    except LocalEntryNotFoundError:
        if os.environ.get("HF_HUB_OFFLINE") == "1":
            raise
        print("GigaAM (речь): скачивание модели…", file=sys.stderr, flush=True)
        path = snapshot_download("istupakov/gigaam-v3-onnx", **options)
    print("GigaAM: загрузка в память…", file=sys.stderr, flush=True)
    model = onnx_asr.load_model("gigaam-v3-e2e-rnnt", path=Path(path), providers=["CPUExecutionProvider"]).with_timestamps()
    return model


def run_gigaam(audio_path: Path):
    """GigaAM v3 RNNT on CPU, 25 s chunks with 1 s overlap."""
    model = load_gigaam_model()
    samples, sr = load_audio(audio_path)
    if sr != 16000 or samples.ndim != 1:
        raise RuntimeError("GigaAM requires 16 kHz mono audio")
    segments = []
    for start in range(0, len(samples), 24 * sr):
        end = min(start + 25 * sr, len(samples))
        result = model.recognize(samples[start:end], sample_rate=sr)
        lower = 0 if start == 0 else start / sr + 0.5
        upper = end / sr + 0.1 if end == len(samples) else start / sr + 24.5
        segments.extend(gigaam_words(result, start / sr, end / sr, lower, upper))
        if end == len(samples):
            break
    return {"segments": segments, "text": " ".join(s["text"] for s in segments)}


def assign_speakers(text_segments: list, diar_segments: list):
    """Align transcription segments with Diarization intervals by maximum overlap."""
    if not diar_segments:
        for seg in text_segments:
            seg["speaker"] = 1
        return text_segments, 1

    diar_sorted = sorted(diar_segments, key=lambda s: s.start)
    speaker_map = {}

    for seg in text_segments:
        w_start = seg["start"]
        w_end = seg["end"]

        # Calculate overlap duration with each diarized speaker
        overlaps = {}
        for d in diar_sorted:
            o_start = max(w_start, d.start)
            o_end = min(w_end, d.end)
            if o_end > o_start:
                overlaps[d.speaker] = overlaps.get(d.speaker, 0.0) + (o_end - o_start)

        if overlaps:
            best_spk = max(overlaps.items(), key=lambda x: x[1])[0]
        else:
            # Nearest diarization segment
            closest = min(diar_sorted, key=lambda d: min(abs(d.start - w_start), abs(d.end - w_end)))
            best_spk = closest.speaker

        if best_spk not in speaker_map:
            speaker_map[best_spk] = len(speaker_map) + 1

        seg["speaker"] = speaker_map[best_spk]

    return text_segments, len(speaker_map)


def write_transcript(output_path: Path, lines: list[str]):
    temporary_output = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output_path.parent,
                                         prefix=f".{output_path.name}.", delete=False) as handle:
            temporary_output = Path(handle.name)
            handle.write("\n".join(lines) + "\n")
        temporary_output.replace(output_path)
    finally:
        if temporary_output is not None:
            temporary_output.unlink(missing_ok=True)


def group_turns(segments: list, breaks=()):
    turns = []
    boundaries = sorted(breaks)
    for seg in segments:
        if not seg["text"].strip():
            continue
        if (turns and turns[-1].get("speaker", 1) == seg.get("speaker", 1)
                and seg["start"] - turns[-1]["end"] < 2
                and seg["end"] - turns[-1]["start"] <= 15
                and bisect_right(boundaries, turns[-1]["start"]) == bisect_right(boundaries, seg["start"])):
            turns[-1]["text"] += " " + seg["text"]
            turns[-1]["end"] = max(turns[-1]["end"], seg["end"])
        else:
            turns.append(dict(seg))
    return turns



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio_path", type=Path, help="Path to source audio")
    parser.add_argument("output_path", type=Path, nargs="?", help="Path to transcript")
    parser.add_argument("--no-diarize", action="store_true", help="Microphone source: one speaker")
    parser.add_argument("--offline", action="store_true", help="Use cached models only")
    parser.add_argument("--segments-json", type=Path, help="Write word timestamps for merging source channels")
    args = parser.parse_args()
    model_name = "gigaam-v3-e2e-rnnt"
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"

    input_path = args.audio_path.resolve()
    if not input_path.is_file():
        print(f"Error: input audio not found: {input_path}", file=sys.stderr, flush=True)
        sys.exit(1)

    if args.output_path:
        output_path = args.output_path.resolve()
    else:
        output_path = input_path.parent / f"{input_path.stem}.local.transcript.txt"

    outputs = [output_path]
    if args.segments_json:
        outputs.append(args.segments_json.resolve())
    for index, output in enumerate(outputs):
        for other in [input_path, *outputs[:index]]:
            if output == other or (output.exists() and other.exists() and output.samefile(other)):
                parser.error("output paths must differ from input audio and each other")
        if not output.parent.is_dir():
            parser.error(f"output directory not found: {output.parent}")

    print(f"Transcribing: {input_path.name}", file=sys.stderr, flush=True)
    start_time = time.time()
    try:
        result = run_gigaam(input_path)
    except Exception as e:
        print(f"Transcription error: {e}", file=sys.stderr, flush=True)
        sys.exit(2)

    t_elapsed = time.time() - start_time
    segments = result.get("segments", [])
    print(f"Transcription finished: {len(segments)} segments in {format_duration(t_elapsed)}", file=sys.stderr, flush=True)

    # Speaker Diarization
    num_detected_speakers = 1
    diarization_status = "disabled"
    if not args.no_diarize:
        try:
            diar_segments, num_detected_speakers = run_nemotron_diarization(input_path)
            segments, num_detected_speakers = assign_speakers(segments, diar_segments)
            diarization_status = "enabled" if diar_segments else "no speech detected"
        except Exception as e:
            diarization_status = "failed"
            num_detected_speakers = 1
            print(f"Warning: Diarization failed ({e}); falling back to single speaker.", file=sys.stderr, flush=True)
            for seg in segments:
                seg["speaker"] = 1

    if args.segments_json:
        write_transcript(args.segments_json.resolve(), [json.dumps({
            "segments": segments,
            "diarization": f"Diarization: {diarization_status} ({num_detected_speakers} speakers)",
        }, ensure_ascii=False, allow_nan=False)])
    segments = group_turns(segments)

    total_elapsed = time.time() - start_time

    lines = [
        f"Transcript: {input_path.name}",
        f"Audio: {input_path}",
        f"Model: {model_name} (ONNX / CPU)",
        f"Diarization: {diarization_status} ({num_detected_speakers} speakers)",
        "Diarization backend: nemotron",
        f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        "",
    ]

    if segments:
        for seg in segments:
            start_s = float(seg.get("start", 0.0))
            text = str(seg.get("text", "")).strip()
            if not text:
                continue
            spk = seg.get("speaker", 1)
            lines.append(f"[{format_timestamp(start_s)}] Speaker {spk}: {text}")
    else:
        text = str(result.get("text", "")).strip()
        lines.append(f"[00:00] Speaker 1: {text}")

    lines.extend([
        "",
        "Speaker guide:",
    ])
    guide = ("Inferred from local nemotron diarization; identities are unverified."
             if diarization_status == "enabled" else
             f"Speaker attribution unavailable: diarization {diarization_status}; Speaker 1 is a placeholder.")
    for s_idx in range(1, num_detected_speakers + 1):
        lines.append(f'Speaker {s_idx}: "{guide}"')

    write_transcript(output_path, lines)

    audio_dur = segments[-1]["end"] if segments else 0.0
    speedup = f" ({audio_dur / total_elapsed:.1f}x realtime)" if audio_dur > 0 and total_elapsed > 0 else ""
    print(
        f"Done: wrote {output_path} ({len(segments)} turns, {num_detected_speakers} speakers, {format_duration(total_elapsed)} total{speedup})",
        file=sys.stderr,
        flush=True,
    )


if __name__ == "__main__":
    main()
