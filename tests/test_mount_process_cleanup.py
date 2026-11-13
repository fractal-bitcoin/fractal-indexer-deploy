"""Test mount worker cleanup using local mock processes, without FUSE."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/mount-kopia-snapshot.sh'
TEXT = SCRIPT.read_text()
FUNCTIONS = TEXT[TEXT.index('unmount_path() {'):TEXT.index('\nload_default_readonly_r2_credentials\n')]


class MountProcessCleanupTests(unittest.TestCase):
    def run_case(self, body, ignore_term=False):
        with tempfile.TemporaryDirectory(prefix='mount worker test ') as directory:
            root = Path(directory).resolve()
            binary = root / 'bin'
            binary.mkdir()
            worker = binary / 'kopia'
            worker.write_text('#!' + sys.executable + '\n' + '''import os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN if os.environ['TEST_IGNORE_TERM'] == '1' else lambda *_: sys.exit(0))
with open(os.environ['TEST_ROOT'] + '/pids', 'a') as f:
    f.write(str(os.getpid()) + '\\n')
Path(sys.argv[3], '.worker-ready').touch()
while True:
    time.sleep(1)
''')
            worker.chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                       TEST_ROOT=str(root), TEST_IGNORE_TERM=str(int(ignore_term)))
            mocks = '''
log() { :; }
warn() { echo "$*" >&2; }
die() { exit 1; }
snapshot_object_id() { echo mock-object; }
mountpoint() { [ -f "$2/.mounted" ]; }
unmount_path() {
  if mountpoint -q "$1"; then
    printf '%s\\n' "${1##*/}" >> "$TEST_ROOT/unmounts"
    rm "$1/.mounted"
  fi
}
sleep() { command sleep 0.01; }
wait_for_mount() {
  local target="$1" attempt
  for ((attempt = 0; attempt < 300; attempt++)); do
    [ -f "$target/.worker-ready" ] && break
    sleep 0.01
  done
  [ -f "$target/.worker-ready" ] || return 1
  # Simulate a mount appearing at the timeout boundary.
  touch "$target/.mounted"
  [ "${target##*/}" != fail ]
}
trap cleanup EXIT
'''
            process = subprocess.Popen(['bash', '-c', 'set -euo pipefail\n' + FUNCTIONS + mocks + body],
                                       cwd=root, env=env, text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=15)
                pidfile = root / 'pids'
                pids = [int(p) for p in pidfile.read_text().splitlines()] if pidfile.exists() else []
                for pid in pids:
                    with self.assertRaises(ProcessLookupError, msg='mount worker must be reaped'):
                        os.kill(pid, 0)
                unmounts = (root / 'unmounts').read_text().splitlines() if (root / 'unmounts').exists() else []
                return process.returncode, unmounts, len(pids), stderr
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()

    def test_timeout_stops_worker_and_removes_late_mount(self):
        code, unmounts, count, _ = self.run_case('mount_dataset test "$TEST_ROOT/fail"')
        self.assertEqual(code, 1)
        self.assertEqual(count, 1)
        self.assertEqual(unmounts, ['fail'])

    def test_partial_failure_cleans_only_this_runs_mounts(self):
        code, unmounts, count, _ = self.run_case('''mkdir "$TEST_ROOT/existing"
touch "$TEST_ROOT/existing/.mounted"
mount_dataset test "$TEST_ROOT/first"
mount_dataset test "$TEST_ROOT/fail"''')
        self.assertEqual(code, 1)
        self.assertEqual(count, 2)
        self.assertEqual(unmounts, ['fail', 'first'])

    def test_existing_mount_does_not_start_or_unmount_worker(self):
        code, unmounts, count, _ = self.run_case('''mkdir "$TEST_ROOT/existing"
touch "$TEST_ROOT/existing/.mounted"
mount_dataset test "$TEST_ROOT/existing"''')
        self.assertEqual(code, 1)
        self.assertEqual(count, 0)
        self.assertEqual(unmounts, [])

    def test_success_cleanup_is_reverse_and_idempotent(self):
        code, unmounts, count, _ = self.run_case('''mount_dataset test "$TEST_ROOT/first"
mount_dataset test "$TEST_ROOT/second"
cleanup
cleanup''')
        self.assertEqual(code, 0)
        self.assertEqual(count, 2)
        self.assertEqual(unmounts, ['second', 'first'])

    def test_term_cleanup_reaps_successful_workers(self):
        code, unmounts, count, _ = self.run_case('''trap 'cleanup; exit 143' TERM
mount_dataset test "$TEST_ROOT/first"
kill -TERM $$''')
        self.assertEqual(code, 143)
        self.assertEqual(count, 1)
        self.assertEqual(unmounts, ['first'])

    def test_unresponsive_worker_is_killed_and_reaped(self):
        code, unmounts, count, stderr = self.run_case('mount_dataset test "$TEST_ROOT/fail"', ignore_term=True)
        self.assertEqual(code, 1)
        self.assertEqual(count, 1)
        self.assertEqual(unmounts, ['fail'])
        self.assertIn('sending KILL', stderr)


if __name__ == '__main__':
    unittest.main()
