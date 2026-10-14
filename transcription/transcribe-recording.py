#!/usr/bin/env python3
"""Transcribe Meeting Companion sources and merge their shared timeline."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

from transcribe import format_timestamp, group_turns, write_transcript


def merge_sources(host_data: dict, remote_data: dict) -> list[str]:
    channels = []
    remote_speakers = set()
    for channel, data in enumerate((host_data, remote_data)):
        words = []
        for seg in data["segments"]:
            if not (math.isfinite(seg["start"]) and math.isfinite(seg["end"])
                    and 0 <= seg["start"] <= seg["end"]
                    and isinstance(seg.get("speaker", 1), int) and seg.get("speaker", 1) >= 1
                    and isinstance(seg["text"], str)):
                raise ValueError(f"Invalid transcript segment: {seg}")
            if not seg["text"].strip():
                continue
            speaker = 1 if channel == 0 else seg.get("speaker", 1) + 1
            if channel:
                remote_speakers.add(speaker)
            words.append({**seg, "speaker": speaker})
        channels.append(sorted(words, key=lambda word: word["start"]))
    status = remote_data.get("diarization", "")
    if not isinstance(status, str) or not status.startswith("Diarization: "):
        raise ValueError("Remote transcript has no diarization status")
    # Keep overlapping utterances intact, but split each channel at the other's turn starts.
    breaks = [turn["start"] for words in channels for turn in group_turns(words)]
    turns = [turn for words in channels for turn in group_turns(words, breaks)]
    lines = ["Host attribution: microphone source", f"Remote {status}", ""]
    lines.extend(f'[{format_timestamp(turn["start"])}] Speaker {turn["speaker"]}: {turn["text"]}'
                 for turn in sorted(turns, key=lambda turn: (turn["start"], turn["speaker"])))
    lines.extend(["", "Speaker guide:", "Speaker 1: Host / microphone source."])
    for speaker in sorted(remote_speakers):
        guide = ("Nemotron voice; identity unverified" if status.startswith("Diarization: enabled")
                 else "placeholder; remote voice attribution unavailable")
        lines.append(f"Speaker {speaker}: Remote / system audio, {guide}.")
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
    runner = Path(__file__).with_name("run.sh")
    options = ["--offline"] if args.offline else []
    with tempfile.TemporaryDirectory(prefix="interview-transcript-") as directory:
        host_json, remote_json = (Path(directory) / name for name in ("host.json", "remote.json"))
        subprocess.run([str(runner), *options, "--no-diarize", "--segments-json", str(host_json),
                        str(host), str(host_output)], check=True)
        subprocess.run([str(runner), *options, "--segments-json", str(remote_json),
                        str(remote), str(remote_output)], check=True)
        lines = [f"Transcript: {base.name} — separate sources", f"Host audio: {host}", f"Remote audio: {remote}"]
        lines.extend(merge_sources(json.loads(host_json.read_text()), json.loads(remote_json.read_text())))
    write_transcript(merged_output, lines)
    print(f"Saved: {merged_output}")


if __name__ == "__main__":
    main()
