import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LauncherTests(unittest.TestCase):
    def run_launcher(self, option, *extra):
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
            return subprocess.run([str(folder / "run.sh"), option, *extra], env=environment,
                                  text=True, capture_output=True, check=True).stdout.splitlines()

    def test_check_uses_private_storage_and_stays_offline(self):
        lines = self.run_launcher("--check")
        root = Path.home() / "Library/Application Support/MeetingCompanion"
        self.assertEqual(lines[:5], [str(root / path) for path in
                         ("runtime/cache", "runtime/python", "models", "models/hub", "models/xet")])
        self.assertEqual(lines[5:7], ["1", "1"])
        self.assertIn("only-managed", lines)
        self.assertTrue(any(line.endswith("/check-local.py") for line in lines))

    def test_parakeet_uses_same_mlx_runtime_without_other_engines(self):
        base = self.run_launcher("--availability")
        enhanced = self.run_launcher("--availability", "--parakeet")
        for lines in (base, enhanced):
            self.assertIn("mlx-audio==0.5.8", lines)
            self.assertFalse(any('transcribe-cpp' in line or 'onnx' in line for line in lines))
        self.assertEqual(enhanced[5:7], ["1", "1"])

    def test_prepare_can_download(self):
        lines = self.run_launcher("--prepare")
        self.assertEqual(lines[5:7], ["", ""])
        self.assertIn("--no-progress", lines)
        self.assertNotIn("--quiet", lines)
        self.assertIn("-u", lines)
        self.assertNotIn("imageio-ffmpeg", lines)


class PermissionResetTests(unittest.TestCase):
    def run_reset(self, answer="y\n", *, process_status=1, system="Darwin", fail_service=""):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            scripts = {
                "uname": "printf '%s\\n' \"$TEST_SYSTEM\"",
                "pgrep": "exit \"$TEST_PROCESS_STATUS\"",
                "tccutil": "printf '%s\\n' \"$*\" >> \"$TEST_RESET_LOG\"; "
                           "if [ \"$2\" = \"$TEST_FAIL_SERVICE\" ]; then exit 1; fi",
            }
            for name, body in scripts.items():
                path = folder / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            log = folder / "reset.log"
            environment = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ["PATH"],
                               TEST_SYSTEM=system, TEST_PROCESS_STATUS=str(process_status),
                               TEST_FAIL_SERVICE=fail_service, TEST_RESET_LOG=str(log))
            script = Path(__file__).resolve().parents[1] / "scripts/reset-permissions.sh"
            result = subprocess.run(["bash", str(script)], input=answer, text=True,
                                    capture_output=True, env=environment)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_confirmed_reset_only_targets_app_and_three_services(self):
        result, calls = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [f"reset {service} local.meeting-companion"
                                for service in ("ScreenCapture", "Microphone", "Calendar")])

    def test_cancel_or_eof_never_resets(self):
        for answer in ("n\n", "\n", ""):
            with self.subTest(answer=answer):
                _, calls = self.run_reset(answer)
                self.assertEqual(calls, [])

    def test_running_app_process_error_and_non_macos_never_reset(self):
        for options in ({"process_status": 0}, {"process_status": 2}, {"system": "Linux"}):
            with self.subTest(options=options):
                result, calls = self.run_reset(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_service_failure_stops_before_remaining_resets(self):
        result, calls = self.run_reset(fail_service="Microphone")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["reset ScreenCapture local.meeting-companion",
                                 "reset Microphone local.meeting-companion"])
        self.assertIn("Не удалось сбросить Microphone", result.stderr)


if __name__ == "__main__":
    unittest.main()
