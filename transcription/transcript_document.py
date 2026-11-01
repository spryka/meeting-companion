"""Immutable recognition snapshots; publication is a single directory rename."""
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import wave

from transcribe import group_turns


def relative_audio(path, root):
    return str(Path(path).resolve().relative_to(root.resolve()))


def warning(code, source, message):
    # Logs retain diagnostic paths; portable documents contain only user-facing text.
    message = re.sub(r"(?<!\w)(?:/|~/)[^\s;,]+", "[path]", str(message))
    return dict(code=code, sourceID=source, message=message)


def build_document(result_id, results, sources, recognition, root, aec, warnings, context):
    document = dict(schemaVersion=1, resultID=result_id,
                    createdAt=datetime.now(timezone.utc).isoformat(), sources=[],
                    speakers=[], words=[], turns=[], baselineWords=[], aec=aec,
                    playback=dict(status="unavailable", mixPath=None),
                    warnings=list(warnings), context=context)
    offset = 1
    channels = []
    for index, (source, data, original, actual) in enumerate(zip(
            ("host", "remote"), results, sources, recognition)):
        status = data["diarization"]
        diarization = ("disabled" if status.startswith("Diarization: disabled") else
                       "failed" if status.startswith("Diarization: failed") else "completed")
        enhancement = data.get("enhancement", "disabled")
        correction = ("completed" if enhancement.startswith("enabled") else
                      "failed" if enhancement.startswith("failed") else "disabled")
        document["sources"].append(dict(
            id=source, originalAudioPath=relative_audio(original, root),
            recognitionAudioPath=relative_audio(actual, root),
            diarizationStatus=diarization,
            detectedVoiceCount=data.get("diarization_speakers", 0) if diarization == "completed" else None,
            correctionStatus=correction))
        for message in data.get("warnings", []):
            document["warnings"].append(warning("recognition_warning", source, message))
        local_ids = set()
        channel = []
        for collection, segments in (("words", data["segments"]),
                                     ("baselineWords", data.get("gigaam_segments", data["segments"]))):
            for number, segment in enumerate(segments):
                start, end = segment["start"], segment["end"]
                local = segment.get("speaker", 1)
                if not (math.isfinite(start) and math.isfinite(end) and 0 <= start <= end
                        and type(local) is int and local >= 1 and isinstance(segment["text"], str)):
                    raise ValueError("Invalid recognition word")
                if not segment["text"].strip():
                    continue
                local_ids.add(local)
                word = dict(id=f"{collection}-{source}-{number}", speakerID=f"{source}-{local}",
                            start=start, end=end, text=segment["text"])
                document[collection].append(word)
                if collection == "words":
                    channel.append({**word, "speaker": local + (offset if index else 0)})
        for local in sorted(local_ids):
            document["speakers"].append(dict(id=f"{source}-{local}", sourceID=source,
                                            localID=local, displayNumber=local + (offset if index else 0)))
        if index == 0:
            offset = max([1, *local_ids])
        channels.append(sorted(channel, key=lambda word: word["start"]))
    breaks = [turn["start"] for channel in channels for turn in group_turns(channel)]
    for channel in channels:
        grouped = group_turns(channel, breaks)
        positions = {word["id"]: i for i, word in enumerate(channel)}
        for i, turn in enumerate(grouped):
            begin = positions[turn["id"]]
            end = positions[grouped[i + 1]["id"]] if i + 1 < len(grouped) else len(channel)
            document["turns"].append(dict(id=f"turn-{turn['id']}", speakerID=turn["speakerID"],
                start=turn["start"], end=turn["end"], wordIDs=[w["id"] for w in channel[begin:end]]))
    display = {speaker["id"]: speaker["displayNumber"] for speaker in document["speakers"]}
    for collection in ("words", "baselineWords", "turns"):
        document[collection].sort(key=lambda item: (item["start"], display[item["speakerID"]]))
    return document


def publish_result(base, results, host, remote, microphone, aec, capture_warnings):
    from transcript_mix import prepare_mix

    root = base.parent.resolve()
    raw = root / "raw"
    relative_audio(raw, root)
    raw.mkdir(exist_ok=True)
    versions = raw / "transcripts"
    relative_audio(versions, root)
    versions.mkdir(exist_ok=True)
    result_id = uuid.uuid4().hex
    destination = versions / result_id
    # Staging is outside the discoverable version directory, even after process death.
    with tempfile.TemporaryDirectory(prefix=".transcript-", dir=raw) as temporary:
        staging = Path(temporary)
        recognition = microphone
        if aec["outcome"] == "applied":
            relative_audio(microphone, root)
            shutil.copyfile(microphone, staging / "microphone.wav")
            recognition = destination / "microphone.wav"
        warnings = [warning("aec_failed" if str(message).startswith("Эхоподавление") else "capture_warning",
                            "host" if str(message).startswith("Эхоподавление") else None, message)
                    for message in capture_warnings]
        context = None
        context_file = base.with_name(base.name + ".context.json")
        if context_file.is_file():
            try:
                saved = json.loads(context_file.read_text())
                if not isinstance(saved, dict):
                    raise ValueError("Invalid calendar context")
                aliases = {"title": "summary", "startAt": "start", "timeZone": "timezone",
                           "agenda": "agenda", "attendees": "attendees"}
                context = {}
                for key, old_key in aliases.items():
                    value = saved.get(key, saved.get(old_key))
                    if value is None:
                        continue
                    if key == "attendees":
                        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
                            raise ValueError("Invalid attendees")
                    elif not isinstance(value, str):
                        raise ValueError("Invalid context field")
                    context[key] = value
            except (OSError, ValueError, TypeError):
                context = None
                warnings.append(warning("context_unavailable", None, "Не удалось прочитать контекст встречи."))
        document = build_document(result_id, results, (host, remote), (recognition, remote),
                                  root, aec, warnings, context)
        try:
            prepare_mix(staging / "microphone.wav" if aec["outcome"] == "applied" else microphone,
                        remote, staging / "mix.m4a")
            document["playback"] = dict(status="ready", mixPath=relative_audio(destination / "mix.m4a", root))
        except (OSError, ValueError, RuntimeError, wave.Error, subprocess.SubprocessError) as error:
            print(f"Transcript mix unavailable: {error}", file=sys.stderr)
            (staging / "mix.m4a").unlink(missing_ok=True)
            document["warnings"].append(warning("playback_mix_failed", None,
                                                "Подготовка микса не удалась; доступен текст."))
        with (staging / "result.json").open("w", encoding="utf-8") as output:
            json.dump(document, output, ensure_ascii=False, allow_nan=False, indent=2)
            output.flush()
            os.fsync(output.fileno())
        staging.rename(destination)
    return destination
