#!/usr/bin/env python3
"""Build the offline AEC helper from pinned headers and the matching ARM64 library."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SHA256 = "46dc45181de1b19cf9a76d2fe3c9107498d5233ea9f7b334e7801b89cec2e090"
URL = ("https://files.pythonhosted.org/packages/77/59/33ad10cf1d7d5280f3d92077f42c262ade6420dcf89525ad18b88595e5c5/"
       "aec_audio_processing-1.0.0.dev9.tar.gz")


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    cache = ROOT / ".build" / "webrtc-aec"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "source.tar.gz"
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        with urllib.request.urlopen(URL, timeout=30) as response:
            data = response.read(20_000_001)
        if hashlib.sha256(data).hexdigest() != SHA256:
            raise ValueError("AEC source checksum mismatch")
        archive.write_bytes(data)
    with tempfile.TemporaryDirectory(dir=cache) as temporary:
        with tarfile.open(archive) as source:
            source.extractall(temporary, filter="data")
        package = Path(temporary) / "aec_audio_processing-1.0.0.dev9"
        project = package / "webrtc-audio-processing"
        library = output / "libwebrtc-audio-processing-2.1.dylib"
        shutil.copyfile(package / "src/files/libwebrtc-audio-processing-2.dylib", library)
        subprocess.run(["install_name_tool", "-id", "@rpath/" + library.name, str(library)], check=True)
        subprocess.run(["clang++", "-std=c++17", "-O2", "-arch", "arm64", "-DNDEBUG",
            "-DWEBRTC_APM_DEBUG_DUMP=0", "-DWEBRTC_POSIX", "-DWEBRTC_MAC",
            "-I" + str(project / "webrtc"), "-I" + str(project / "subprojects/abseil-cpp-20240722.0"),
            str(ROOT / "transcription/aec.cpp"), str(library), "-Wl,-rpath,@executable_path",
            "-o", str(output / "meeting-aec")], check=True)
        notices = []
        for path in sorted(package.rglob("*")):
            if path.is_file() and (path.name.startswith(("LICENSE", "COPYING")) or path.name in ("PATENTS", "AUTHORS")):
                if any(part in ("build", "install") for part in path.relative_to(package).parts):
                    continue
                notices.append(str(path.relative_to(package)) + "\n\n" + path.read_text(errors="replace"))
        (output / "THIRD_PARTY_NOTICES.txt").write_text("\n\n---\n\n".join(notices))


if __name__ == "__main__":
    main()
