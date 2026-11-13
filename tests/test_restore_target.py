"""Test restore target checks without sudo, Docker, or Kopia operations."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/restore-kopia-snapshot.sh'
TEXT = SCRIPT.read_text()
CHECKS = TEXT[TEXT.index('validate_restore_target() {'):TEXT.index('\nrequire_command realpath')]


class RestoreTargetTests(unittest.TestCase):
    def run_check(self, target, *, content=False, yes=False, delete=True, setup=None, confirmation=None):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            repo = base / 'repo'
            repo.mkdir()
            home = base / 'home'
            home.mkdir()
            cwd = base / 'working'
            cwd.mkdir()
            data = base / 'data'
            data.mkdir()
            if content:
                (data / '.hidden').write_text('keep me')
            if setup:
                setup(base)
            paths = {'root': '/', 'repo': str(repo), 'ancestor': str(base),
                     'home': str(home), 'cwd': str(cwd), 'data': str(data),
                     'new': str(base / 'new' / 'data'), 'file': str(data / '.hidden'),
                     'system': '/proc/fractal', 'link': str(base / 'link')}
            env = dict(os.environ, HOME=str(home), REPO_ROOT=str(repo),
                       TEST_TARGET=paths[target], TEST_PYTHON=sys.executable,
                       TEST_YES=str(int(yes)), TEST_DELETE=str(int(delete)))
            # macOS realpath lacks GNU -m/-e; emulate canonicalization only in
            # this isolated fixture. Production uses GNU realpath on Linux.
            shell = '''set -euo pipefail
die() { echo "$*" >&2; exit 1; }
warn() { echo "$*" >&2; }
realpath() {
  "$TEST_PYTHON" -c 'import os,sys; p=sys.argv[-1]; assert sys.argv[1] != "-e" or os.path.exists(p); print(os.path.realpath(p))' "$@"
}
target="$TEST_TARGET"
snapshot_height=123
dataset=fractald-blocks
delete_extra="$TEST_DELETE"
assume_yes="$TEST_YES"
'''
            master = slave = None
            try:
                if confirmation is not None:
                    master, slave = os.openpty()
                    answer = paths[target] if confirmation == 'correct' else 'wrong'
                    os.write(master, (answer + '\n').encode())
                return subprocess.run(['bash', '-c', shell + CHECKS + '\nvalidate_restore_target\nconfirm_restore_target'],
                                      cwd=cwd, env=env,
                                      stdin=slave if slave is not None else subprocess.DEVNULL,
                                      capture_output=True, text=True, timeout=10)
            finally:
                if master is not None:
                    os.close(master)
                    os.close(slave)

    def test_root_rejected_even_with_yes(self):
        self.assertNotEqual(self.run_check('root', yes=True).returncode, 0)

    def test_other_directory_locations_allowed(self):
        for target in ('repo', 'ancestor', 'home', 'cwd', 'system'):
            with self.subTest(target=target):
                result = self.run_check(target, yes=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_symlink_to_root_rejected(self):
        result = self.run_check('link', setup=lambda base: (base / 'link').symlink_to('/'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unsafe restore target', result.stderr)

    def test_file_rejected(self):
        result = self.run_check('file', content=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a directory', result.stderr)

    def test_empty_and_new_targets_pass(self):
        for target in ('data', 'new'):
            with self.subTest(target=target):
                result = self.run_check(target)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_hidden_file_requires_confirmation(self):
        result = self.run_check('data', content=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nonempty target requires interactive confirmation', result.stderr)
        self.assertIn('height 123', result.stderr)

    def test_correct_path_confirms_restore(self):
        result = self.run_check('data', content=True, confirmation='correct')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_path_cancels_restore(self):
        result = self.run_check('data', content=True, confirmation='wrong')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('restore cancelled', result.stderr)

    def test_yes_allows_nonempty_target(self):
        result = self.run_check('data', content=True, yes=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('files absent from the snapshot will be deleted', result.stderr)

    def test_no_delete_extra_skips_confirmation(self):
        result = self.run_check('data', content=True, delete=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_no_delete_extra_still_rejects_root(self):
        self.assertNotEqual(self.run_check('root', delete=False).returncode, 0)


if __name__ == '__main__':
    unittest.main()
