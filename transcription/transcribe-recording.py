#!/usr/bin/env python3
"""Transcribe Meeting Companion sources and merge their shared timeline."""
import argparse
import json
import math
from pathlib import Path
import os

from transcribe import format_timestamp, group_turns, transcribe_file, write_transcript


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
    return tuple(base.with_name(base.name + f".{source}_record.wav") for source in ("host", "remote"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path, help="Combined recording path or its filename stem")
    parser.add_argument("--offline", action="store_true", help="Use cached models and packages")
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
    for output in (host_output, remote_output, merged_output):
        for source in (host, remote, args.recording.resolve()):
            if output.exists() and source.exists() and output.samefile(source):
                parser.error(f"Transcript output aliases source audio: {output}")
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    results = []
    for channel, source, output in (("host", host, host_output), ("remote", remote, remote_output)):
        def progress(stage, completed, total):
            print("MEETING_PROGRESS " + json.dumps({"stage": stage, "channel": channel,
                  "completed": completed, "total": total}), flush=True)
        # shortcut: preserve the host preset until dual-source diarization is enabled.
        results.append(transcribe_file(source, output, diarize=channel != "host", on_progress=progress))
    print('MEETING_PROGRESS {"stage":"merge","completed":0,"total":1}', flush=True)
    lines = [f"Transcript: {base.name} — separate sources", f"Host audio: {host}", f"Remote audio: {remote}"]
    lines.extend(merge_sources(*results))
    write_transcript(merged_output, lines)
    print('MEETING_PROGRESS {"stage":"merge","completed":1,"total":1}', flush=True)
    print(f"Saved: {merged_output}")


if __name__ == "__main__":
    main()
