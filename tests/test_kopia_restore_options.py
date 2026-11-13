"""Check restore flag composition without connecting to Kopia."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'scripts/lib.sh'


class KopiaRestoreOptionsTests(unittest.TestCase):
    def restore_args(self, skip=None, delete=False, object_id='selected-root'):
        with tempfile.TemporaryDirectory(prefix='restore options ') as directory:
            args_file = Path(directory) / 'args'
            env = dict(os.environ, TEST_LIB=str(LIB), TEST_ARGS=str(args_file),
                       TEST_TARGET=str(Path(directory) / 'target'),
                       TEST_DELETE=str(int(delete)), TEST_OBJECT=object_id)
            shell = '''set -euo pipefail
. "$TEST_LIB"
kopia() { printf '%s\\n' "$@" > "$TEST_ARGS"; }
kopia_snapshot_object_id() { printf 'resolved-root'; }
'''
            call = 'kopia_restore_snapshot_dataset 123 fractald-blocks "$TEST_TARGET" "$TEST_DELETE" "$TEST_OBJECT"'
            if skip is not None:
                call += ' ' + str(int(skip))
            result = subprocess.run(['bash', '-c', shell + call], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return args_file.read_text().splitlines()

    def test_existing_callers_still_skip_by_default(self):
        args = self.restore_args()
        self.assertIn('--skip-existing', args)
        self.assertNotIn('--no-skip-existing', args)
        self.assertEqual(args[:3], ['snapshot', 'restore', 'selected-root'])

    def test_skip_and_delete_flags_are_independent(self):
        for skip in (False, True):
            for delete in (False, True):
                with self.subTest(skip=skip, delete=delete):
                    args = self.restore_args(skip=skip, delete=delete)
                    self.assertEqual('--skip-existing' in args, skip)
                    self.assertEqual('--no-skip-existing' in args, not skip)
                    self.assertEqual('--delete-extra' in args, delete)
                    self.assertIn('--write-files-atomically', args)

    def test_overwrite_mode_still_resolves_root(self):
        args = self.restore_args(skip=False, object_id='')
        self.assertEqual(args[:3], ['snapshot', 'restore', 'resolved-root'])
        self.assertIn('--no-skip-existing', args)


if __name__ == '__main__':
    unittest.main()
