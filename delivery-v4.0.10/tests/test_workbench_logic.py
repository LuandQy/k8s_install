"""Run the browser-free workbench logic tests with Node when available."""
import os
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NODE = os.environ.get('NODE') or shutil.which('node')


class WorkbenchLogicTests(unittest.TestCase):
    @unittest.skipUnless(NODE, 'node not available for frontend logic tests')
    def test_clone_prune_and_visibility(self):
        result = subprocess.run([NODE, str(ROOT / 'tests' / 'workbench-logic.test.js')],
                                cwd=str(ROOT), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('WORKBENCH_LOGIC_OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
