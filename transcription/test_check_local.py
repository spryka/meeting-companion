import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_local", Path(__file__).with_name("check-local.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

class DiagnosticTests(unittest.TestCase):
    def test_individual_failure_is_named_and_does_not_hide_other_checks(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertFalse(check.check("GigaAM", lambda: (_ for _ in ()).throw(RuntimeError("cache missing"))))
            self.assertTrue(check.check("Nemotron", lambda: None))
        self.assertIn("ERROR: GigaAM: cache missing", output.getvalue())
        self.assertIn("OK: Nemotron", output.getvalue())
        self.assertLess(output.getvalue().index("Этап: GigaAM"), output.getvalue().index("ERROR: GigaAM"))

if __name__ == "__main__":
    unittest.main()
