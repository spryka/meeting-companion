import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LauncherTests(unittest.TestCase):
    def run_launcher(self, option):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            shutil.copy2(Path(__file__).with_name("run.sh"), folder / "run.sh")
            uv = folder / "uv"
            uv.write_text('''#!/bin/sh
printf '%s\\n' "$UV_CACHE_DIR" "$UV_PYTHON_INSTALL_DIR" "$HF_HOME" "$HF_HUB_CACHE" "$HF_XET_CACHE" "${UV_OFFLINE:-}" "${HF_HUB_OFFLINE:-}" "$@"
''')
            uv.chmod(0o755)
            environment = dict(os.environ)
            environment.pop("UV_OFFLINE", None)
            environment.pop("HF_HUB_OFFLINE", None)
            environment.update(HF_HOME="/shared-models", UV_CACHE_DIR="/shared-packages")
            return subprocess.run([str(folder / "run.sh"), option], env=environment,
                                  text=True, capture_output=True, check=True).stdout.splitlines()

    def test_check_uses_private_storage_and_stays_offline(self):
        lines = self.run_launcher("--check")
        root = Path.home() / "Library/Application Support/InterviewRecorder"
        self.assertEqual(lines[:5], [str(root / path) for path in
                         ("runtime/cache", "runtime/python", "models", "models/hub", "models/xet")])
        self.assertEqual(lines[5:7], ["1", "1"])
        self.assertIn("only-managed", lines)
        self.assertTrue(any(line.endswith("/check-local.py") for line in lines))

    def test_prepare_can_download(self):
        lines = self.run_launcher("--prepare")
        self.assertEqual(lines[5:7], ["", ""])
        self.assertIn("--no-progress", lines)
        self.assertNotIn("--quiet", lines)
        self.assertIn("-u", lines)
        self.assertNotIn("imageio-ffmpeg", lines)


if __name__ == "__main__":
    unittest.main()
