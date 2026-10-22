#!/usr/bin/env python3
"""Transcribe Meeting Companion sources and merge their shared timeline."""
import argparse
import json
import math
from pathlib import Path
import os
import wave

from transcribe import (DIARIZATION_LIMIT_NOTE, NEMOTRON_MAX_SPEAKERS,
                        format_timestamp, group_turns, transcribe_file, write_transcript)
from echo_cancellation import cancel_echo


def merge_sources(host_data: dict, remote_data: dict) -> list[str]:
    channels = []
    source_speakers = [set(), set()]
    remote_offset = 1
    for channel, data in enumerate((host_data, remote_data)):
        words = []
        status = data.get("diarization", "")
        if not isinstance(status, str) or not status.startswith("Diarization: "):
            raise ValueError("Source transcript has no diarization status")
        for seg in data["segments"]:
            if not (math.isfinite(seg["start"]) and math.isfinite(seg["end"])
                    and 0 <= seg["start"] <= seg["end"]
                    and isinstance(seg.get("speaker", 1), int) and seg.get("speaker", 1) >= 1
                    and isinstance(seg["text"], str)):
                raise ValueError(f"Invalid transcript segment: {seg}")
            if not seg["text"].strip():
                continue
            speaker = seg.get("speaker", 1) + (remote_offset if channel else 0)
            if channel == 0:
                remote_offset = max(remote_offset, speaker)
            source_speakers[channel].add(speaker)
            words.append({**seg, "speaker": speaker})
        channels.append(sorted(words, key=lambda word: word["start"]))
    # Keep overlapping utterances intact, but split each channel at the other's turn starts.
    breaks = [turn["start"] for words in channels for turn in group_turns(words)]
    turns = [turn for words in channels for turn in group_turns(words, breaks)]
    host_status = ("Host attribution: microphone source" if host_data["diarization"].startswith("Diarization: disabled")
                   else "Host " + host_data["diarization"])
    lines = [host_status, "Remote " + remote_data["diarization"], ""]
    if any(data["diarization"].startswith("Diarization: enabled") for data in (host_data, remote_data)):
        lines.insert(-1, "Diarization limit: " + DIARIZATION_LIMIT_NOTE)
    for label, data in (("Микрофон", host_data), ("Системный звук", remote_data)):
        lines[-1:-1] = [f"Warning: {label}: {message}" for message in data.get("warnings", [])]
    lines.extend(f'[{format_timestamp(turn["start"])}] Speaker {turn["speaker"]}: {turn["text"]}'
                 for turn in sorted(turns, key=lambda turn: (turn["start"], turn["speaker"])))
    if host_data["diarization"].startswith("Diarization: disabled"):
        source_speakers[0].add(1)
    lines.extend(["", "Speaker guide:"])
    for label, data, speakers in zip(("Host / microphone source", "Remote / system audio"),
                                      (host_data, remote_data), source_speakers):
        for speaker in sorted(speakers):
            status = data["diarization"]
            if status.startswith("Diarization: disabled") and label.startswith("Host"):
                lines.append(f"Speaker {speaker}: {label}.")
            else:
                guide = ("Nemotron voice; identity unverified" if status.startswith("Diarization: enabled")
                         else ("placeholder; remote voice attribution unavailable" if label.startswith("Remote")
                               else "placeholder; microphone voice attribution unavailable"))
                lines.append(f"Speaker {speaker}: {label}, {guide}.")
    return lines


def source_paths(base: Path):
    raw = base.parent / "raw"
    source_base = raw / base.name if raw.is_dir() else base
    return tuple(source_base.with_name(base.name + f".{source}_record.wav") for source in ("host", "remote"))


def meeting_context_warnings(base: Path):
    context = base.with_name(base.name + ".context.json")
    if not context.is_file():
        return []
    try:
        data = json.loads(context.read_text())
        attendees = data.get("attendees", [])
        if not isinstance(attendees, list) or not all(isinstance(name, str) for name in attendees):
            raise ValueError("attendees must be a list of strings")
        count = sum(bool(name.strip()) for name in attendees)
        if count >= NEMOTRON_MAX_SPEAKERS:
            return [f"В контексте встречи указано участников: {count}. Это не число реально говоривших. "
                    f"Лимит Nemotron — {NEMOTRON_MAX_SPEAKERS} голосов на дорожку: возможны объединение "
                    "разных людей под одним Speaker и ошибки авторства. При суммаризации проверяйте "
                    "авторов решений и поручений; число Speaker не подтверждает число участников."]
    except (OSError, ValueError, TypeError, AttributeError) as error:
        return ["Не удалось проверить число участников по сохранённому контексту: " + str(error)]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path, help="Combined recording path or its filename stem")
    parser.add_argument("--parakeet", action="store_true", help="Improve technical terms")
    parser.add_argument("--offline", action="store_true", help="Use cached models and packages")
    parser.add_argument("--echo-cancel", action="store_true", help="Offline AEC3 copy of the microphone (beta)")
    args = parser.parse_args()
    base = args.recording.resolve()
    if base.suffix in (".m4a", ".mp4"):
        base = base.with_suffix("")
    host, remote = source_paths(base)
    for source in (host, remote):
        if not source.is_file():
            parser.error(f"Missing source recording: {source}")
    host_output = host.with_suffix(".local.transcript.txt")
    remote_output = remote.with_suffix(".local.transcript.txt")
    merged_output = base.with_name(base.name + ".sources.transcript.txt")
    original_output = host.parent / (base.name + ".sources.gigaam.transcript.txt")
    outputs = [host_output, remote_output, merged_output]
    if args.parakeet:
        outputs += [original_output, host_output.with_suffix(".gigaam.txt"), remote_output.with_suffix(".gigaam.txt"),
                    host_output.with_suffix(".corrections.json"), remote_output.with_suffix(".corrections.json")]
    for output in outputs:
        for source in (host, remote, args.recording.resolve()):
            if output.exists() and source.exists() and output.samefile(source):
                parser.error(f"Transcript output aliases source audio: {output}")
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    capture_warnings = meeting_context_warnings(base)
    capture_report = host.parent / (base.name + '.capture-report.json')
    if capture_report.is_file():
        try:
            report = json.loads(capture_report.read_text())
            if report.get('droppedBuffers', 0):
                capture_warnings.append(f"При захвате пропущено буферов: {report['droppedBuffers']}; "
                    f"{report.get('droppedSourceSeconds', 0):.3f} с суммарно по дорожкам.")
            if report.get('exportFailure'):
                capture_warnings.append('Общая запись не собрана: ' + str(report['exportFailure']))
            if report.get('failure'):
                capture_warnings.append('Сбой захвата: ' + str(report['failure']))
            if report.get('microphoneRecoveries'):
                capture_warnings.append(f"Попыток восстановления микрофона: {report['microphoneRecoveries']}. "
                                        "В эти моменты возможны пропуски речи.")
            if report.get('microphoneMissing'):
                capture_warnings.append("Во время записи переставали поступать данные микрофона; "
                                        "часть речи могла не сохраниться. Отсутствие реплик не доказывает молчание участника.")
        except (OSError, ValueError, TypeError, AttributeError) as error:
            capture_warnings.append('Не удалось прочитать журнал захвата: ' + str(error))
    for message in capture_warnings:
        print('MEETING_PROGRESS ' + json.dumps(dict(stage='warning', completed=0, total=1,
              warning=message[:1000])), flush=True)
    results = []
    stages = ["diarization", "vad", "gigaam", "speakers"] + (["parakeet", "correction"] if args.parakeet else [])
    steps = 2 * len(stages) + 1 + int(args.echo_cancel)
    microphone = host
    if args.echo_cancel:
        def echo_progress(completed, total):
            print("MEETING_PROGRESS " + json.dumps(dict(stage="echo", channel="host",
                  completed=math.ceil(total / 16000) if completed == total else completed // 16000,
                  total=math.ceil(total / 16000), step=1, steps=steps)), flush=True)
        echo_progress(0, 1)
        try:
            microphone = cancel_echo(host, remote, echo_progress)
        except (OSError, ValueError, RuntimeError, EOFError, wave.Error) as error:
            message = "Эхоподавление не выполнено; распознаётся исходный микрофон: " + str(error)
            capture_warnings.append(message)
            print("MEETING_PROGRESS " + json.dumps(dict(stage="warning", channel="host", completed=0,
                  total=1, warning=message[:1000])), flush=True)
        echo_progress(1, 1)
    for channel_index, (channel, source, output) in enumerate((("host", microphone, host_output), ("remote", remote, remote_output))):
        def progress(stage, completed, total):
            print("MEETING_PROGRESS " + json.dumps({"stage": stage, "channel": channel,
                  "completed": completed, "total": total,
                  "step": channel_index * len(stages) + stages.index(stage) + 1 + int(args.echo_cancel), "steps": steps}), flush=True)
        def warning(message):
            print('MEETING_PROGRESS ' + json.dumps(dict(stage='warning', completed=0, total=1,
                  warning=message[:1000], channel=channel)), flush=True)
        results.append(transcribe_file(source, output, vad=True, parakeet=args.parakeet,
                                       on_progress=progress, on_warning=warning))
    print("MEETING_PROGRESS " + json.dumps(dict(stage="merge", completed=0, total=1, step=steps, steps=steps)), flush=True)
    lines = [f"Transcript: {base.name} — separate sources", f"Host audio: {os.path.relpath(host, merged_output.parent)}", f"Remote audio: {os.path.relpath(remote, merged_output.parent)}"]
    if microphone != host:
        lines.append("Microphone processing: WebRTC AEC3 (beta); " + os.path.relpath(microphone, merged_output.parent))
    lines.extend('Warning: ' + message for message in capture_warnings)
    lines.extend(merge_sources(*results))
    if args.parakeet:
        originals = [{**data, "segments": data["gigaam_segments"]} for data in results]
        write_transcript(original_output, [f"Transcript: {base.name} — original GigaAM",
            *("Warning: " + message for message in capture_warnings), *merge_sources(*originals)])
    write_transcript(merged_output, lines)
    print("MEETING_PROGRESS " + json.dumps(dict(stage="merge", completed=1, total=1, step=steps, steps=steps)), flush=True)
    print(f"Saved: {merged_output}")


if __name__ == "__main__":
    main()
