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

NEMOTRON_MAX_SPEAKERS = 8
DIARIZATION_LIMIT_NOTE = (
    f"Nemotron различает не более {NEMOTRON_MAX_SPEAKERS} голосов на одной дорожке. "
    "Speaker — метка модели, не подтверждённая личность; меньшее число меток не гарантирует точность.")


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
    from mlx_audio.vad import load
    from model_assets import model_path
    path = model_path('nemotron', download=os.environ.get('HF_HUB_OFFLINE') != '1')
    print("Nemotron: загрузка в память…", file=sys.stderr, flush=True)
    model = load(path, strict=True)
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
                and isinstance(seg.speaker, int) and 0 <= seg.speaker < NEMOTRON_MAX_SPEAKERS):
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
    from model_assets import model_path
    path = model_path('gigaam', download=os.environ.get('HF_HUB_OFFLINE') != '1')
    print("GigaAM: загрузка в память…", file=sys.stderr, flush=True)
    return onnx_asr.load_model("gigaam-v3-e2e-rnnt", path=path, providers=["CPUExecutionProvider"]).with_timestamps()


def run_gigaam(audio_path: Path, on_progress=None, keep=None):
    """GigaAM v3 RNNT on CPU, 25 s chunks with 1 s overlap."""
    model = load_gigaam_model()
    samples, sr = load_audio(audio_path)
    if sr != 16000 or samples.ndim != 1:
        raise RuntimeError("GigaAM requires 16 kHz mono audio")
    from audio_enhancement import windows
    grid = list(windows(len(samples), sr))
    keep = [True] * len(grid) if keep is None else keep
    if len(keep) != len(grid):
        raise ValueError("GigaAM window mask does not match audio")
    segments = []
    total = len(grid)
    if on_progress:
        on_progress("gigaam", 0, total)
    for index, ((start, end), speech) in enumerate(zip(grid, keep), 1):
        if speech:
            result = model.recognize(samples[start:end], sample_rate=sr)
            lower = 0 if start == 0 else start / sr + 0.5
            upper = end / sr + 0.1 if end == len(samples) else start / sr + 24.5
            segments.extend(gigaam_words(result, start / sr, end / sr, lower, upper))
        if on_progress:
            on_progress("gigaam", index, total)
    return {"segments": segments, "text": " ".join(s["text"] for s in segments)}


def assign_speakers(text_segments: list, diar_segments: list, on_progress=None):
    """Find overlapping intervals with a prefix-end index, preserving tie order."""
    from bisect import bisect_left, bisect_right
    if on_progress:
        on_progress("speakers", 0, len(text_segments))
    diar_sorted = sorted(diar_segments, key=lambda s: s.start)
    starts = [d.start for d in diar_sorted]
    prefix_ends = []
    for d in diar_sorted:
        prefix_ends.append(max(prefix_ends[-1] if prefix_ends else 0, d.end))
    # Sorted unique boundaries retain the first interval for deterministic nearest ties.
    def boundaries(attribute):
        first = {}
        for index, d in enumerate(diar_sorted):
            first.setdefault(getattr(d, attribute), index)
        values = sorted(first)
        return values, first
    start_values, start_indices = boundaries('start')
    end_values, end_indices = boundaries('end')
    speaker_map = {}
    for number, seg in enumerate(text_segments, 1):
        w_start, w_end = seg["start"], seg["end"]
        overlaps = {}
        lower = bisect_right(prefix_ends, w_start)
        upper = bisect_left(starts, w_end)
        for index in range(lower, upper):
            d = diar_sorted[index]
            overlap = min(w_end, d.end) - max(w_start, d.start)
            if overlap > 0:
                overlaps[d.speaker] = overlaps.get(d.speaker, 0.0) + overlap
        if overlaps:
            best_spk = max(overlaps, key=overlaps.get)
        elif diar_sorted:
            candidates = []
            for values, indices, at in ((start_values, start_indices, w_start), (end_values, end_indices, w_end)):
                point = bisect_left(values, at)
                for index in (point-1, point):
                    if 0 <= index < len(values):
                        candidates.append((abs(values[index]-at), indices[values[index]]))
            best_spk = diar_sorted[min(candidates)[1]].speaker
        else:
            best_spk = 0
        if best_spk not in speaker_map:
            speaker_map[best_spk] = len(speaker_map) + 1
        seg["speaker"] = speaker_map[best_spk]
        if on_progress and (number % 500 == 0 or number == len(text_segments)):
            on_progress("speakers", number, len(text_segments))
    return text_segments, len(speaker_map) if diar_sorted else 1


def write_transcript(output_path: Path, lines: list[str]):
    temporary_output = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output_path.parent,
                                         prefix=f".{output_path.name}.", delete=False) as handle:
            temporary_output = Path(handle.name)
            # Redact diagnostic metadata only; never rewrite words spoken in the meeting.
            safe_lines = [line.replace(str(Path.home()), "~") if line.startswith(("Warning:", "Audio:", "Host audio:", "Remote audio:")) else line for line in lines]
            handle.write("\n".join(safe_lines) + "\n")
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


def transcript_lines(input_path, segments, diarization_status, speaker_count, fallback_text="", warnings=()):
    lines = [f"Transcript: {input_path.name}", f"Audio: {input_path.name}",
             "Model: gigaam-v3-e2e-rnnt (ONNX / CPU)",
             f"Diarization: {diarization_status} ({speaker_count} speakers)",
             "Diarization backend: nemotron", f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}", ""]
    if diarization_status == "enabled":
        lines.insert(-1, "Diarization limit: " + DIARIZATION_LIMIT_NOTE)
    lines[-1:-1] = ["Warning: " + warning for warning in warnings]
    turns = group_turns(segments)
    if turns:
        lines.extend(f'[{format_timestamp(turn["start"])}] Speaker {turn.get("speaker", 1)}: {turn["text"]}'
                     for turn in turns)
    else:
        lines.append(f"[00:00] Speaker 1: {str(fallback_text).strip()}")
    lines.extend(["", "Speaker guide:"])
    guide = ("Inferred from local nemotron diarization; identities are unverified."
             if diarization_status == "enabled" else
             f"Speaker attribution unavailable: diarization {diarization_status}; Speaker 1 is a placeholder.")
    lines.extend(f'Speaker {index}: "{guide}"' for index in range(1, speaker_count + 1))
    return lines


def validate_outputs(input_path, output_path, segments_json=None, extra_outputs=()):
    outputs = [output_path] + ([segments_json] if segments_json else []) + list(extra_outputs)
    for index, output in enumerate(outputs):
        for other in [input_path, *outputs[:index]]:
            if output == other or (output.exists() and other.exists() and output.samefile(other)):
                raise ValueError("output paths must differ from input audio and each other")
        if not output.parent.is_dir():
            raise ValueError(f"output directory not found: {output.parent}")


def transcribe_file(input_path: Path, output_path: Path, *, diarize=True,
                    segments_json=None, on_progress=None, vad=False, parakeet=False, on_warning=None):
    """Process either source channel; CLI and recording orchestration share this path."""
    input_path, output_path = input_path.resolve(), output_path.resolve()
    segments_json = segments_json.resolve() if segments_json else None
    original_output = output_path.with_suffix(".gigaam.txt")
    corrections_output = output_path.with_suffix(".corrections.json")
    validate_outputs(input_path, output_path, segments_json,
                     [original_output, corrections_output] if parakeet else [])
    print(f"Transcribing: {input_path.name}", file=sys.stderr, flush=True)
    start_time = time.time()
    warnings = []
    def warn(message):
        warnings.append(message)
        print('Warning: ' + message, file=sys.stderr, flush=True)
        if on_warning:
            on_warning(message)
    num_detected_speakers = 1
    diarization_speakers = 0
    diarization_status = "disabled"
    diar_segments = []
    if diarize:
        if on_progress:
            on_progress("diarization", 0, 1)
        try:
            diar_segments, num_detected_speakers = run_nemotron_diarization(input_path)
            diarization_speakers = num_detected_speakers
            diarization_status = "enabled" if diar_segments else "no speech detected"
            if diarization_speakers >= NEMOTRON_MAX_SPEAKERS:
                warn(f"Nemotron достиг лимита {NEMOTRON_MAX_SPEAKERS} голосов на дорожке. "
                     "Разные люди могут иметь одну метку Speaker. При суммаризации не приписывайте "
                     "решения и поручения конкретным людям без проверки авторства.")
        except Exception as error:
            diarization_status = "failed"
            warn(f'Разделение голосов не выполнено: {error}')
        if on_progress:
            on_progress("diarization", 1, 1)

    keep = None
    if vad:
        if on_progress:
            on_progress("vad", 0, 1)
        try:
            from audio_enhancement import load_vad, speech_windows
            samples, rate = load_audio(input_path)
            keep = speech_windows(samples, rate, load_vad())
            del samples
        except Exception as error:
            warn(f'Пропуск тишины недоступен; распознаём весь звук: {error}')
        if on_progress:
            on_progress("vad", 1, 1)
    result = run_gigaam(input_path, on_progress=on_progress, keep=keep)
    segments = result.get("segments", [])
    if diarize:
        segments, num_detected_speakers = assign_speakers(segments, diar_segments, on_progress=on_progress)
    original_segments = [dict(word) for word in segments]
    enhancement_status = "disabled"
    if parakeet:
        write_transcript(original_output, transcript_lines(input_path, original_segments,
                         diarization_status, num_detected_speakers, fallback_text=result.get("text", ""), warnings=warnings))
        try:
            from audio_enhancement import run_parakeet, windows
            from term_correction import cascade
            if keep is None:
                import soundfile as sf
                keep = [True] * len(list(windows(sf.info(input_path).frames)))
            donor = run_parakeet(input_path, keep, on_progress=on_progress)
            if on_progress:
                on_progress("correction", 0, 1)
            corrected, suggestions = cascade(segments, donor)
            changes = [row for row in suggestions if row['applied']]
            write_transcript(corrections_output, [json.dumps({
                'changes': changes, 'suggestions': suggestions,
                'gigaam_segments': original_segments,
                'donor_segments': donor}, ensure_ascii=False, allow_nan=False)])
            segments = corrected
            enhancement_status = f'enabled ({len(changes)} replacements, {len(suggestions)-len(changes)} suggestions retained in journal)'
            if on_progress:
                on_progress("correction", 1, 1)
        except Exception as error:
            enhancement_status = "failed; original GigaAM retained"
            warn(f'Parakeet не выполнен; сохранён исходный текст GigaAM: {error}')

    data = {"segments": segments, "gigaam_segments": original_segments,
            "enhancement": enhancement_status, "warnings": warnings,
            "diarization_speakers": diarization_speakers,
            "diarization_speaker_limit": NEMOTRON_MAX_SPEAKERS if diarize else None,
            "diarization": f"Diarization: {diarization_status} ({num_detected_speakers} speakers)"}
    if segments_json:
        write_transcript(segments_json, [json.dumps(data, ensure_ascii=False, allow_nan=False)])
    lines = transcript_lines(input_path, segments, diarization_status, num_detected_speakers,
                             fallback_text=result.get("text", ""), warnings=warnings)
    if parakeet:
        lines.insert(5, "Term enhancement: " + enhancement_status)
    write_transcript(output_path, lines)
    total_elapsed = time.time() - start_time
    turns = group_turns(segments)

    audio_dur = segments[-1]["end"] if segments else 0.0
    speedup = f" ({audio_dur / total_elapsed:.1f}x realtime)" if audio_dur > 0 and total_elapsed > 0 else ""
    print(
        f"Done: wrote {output_path} ({len(turns)} turns, {num_detected_speakers} speakers, {format_duration(total_elapsed)} total{speedup})",
        file=sys.stderr,
        flush=True,
    )
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio_path", type=Path, help="Path to source audio")
    parser.add_argument("output_path", type=Path, nargs="?", help="Path to transcript")
    parser.add_argument("--no-diarize", action="store_true", help="Treat the input as one speaker")
    parser.add_argument("--vad", action="store_true", help="Skip silent ASR windows")
    parser.add_argument("--parakeet", action="store_true", help="Improve technical terms with Parakeet")
    parser.add_argument("--offline", action="store_true", help="Use cached models only")
    parser.add_argument("--segments-json", type=Path, help="Write word timestamps for merging source channels")
    args = parser.parse_args()
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

    segments_json = args.segments_json.resolve() if args.segments_json else None
    try:
        validate_outputs(input_path, output_path, segments_json)
    except ValueError as error:
        parser.error(str(error))
    try:
        transcribe_file(input_path, output_path, diarize=not args.no_diarize,
                        segments_json=segments_json, vad=args.vad, parakeet=args.parakeet)
    except Exception as error:
        print(f"Transcription error: {error}", file=sys.stderr, flush=True)
        sys.exit(2)


if __name__ == "__main__":
    main()
