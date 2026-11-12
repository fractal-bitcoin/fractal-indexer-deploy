"""Run with: python3 -m unittest discover -s tests -p 'test_upload_consistency.py'."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/upload-kopia-snapshots.sh'
TEXT = SCRIPT.read_text()
CHECKS = TEXT[TEXT.index('assert_source_containers_stopped() {'):TEXT.index('\nlog "Checking that source containers are stopped"')]


class UploadConsistencyTests(unittest.TestCase):
    def check(self, containers, body='assert_source_containers_stopped', ps_fail=False, inspect_fail=False):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory).resolve() / 'source'
            source.mkdir()
            normalized = json.dumps(containers).replace('SOURCE', str(source))
            env = dict(os.environ, TEST_CONTAINERS=normalized, TEST_PS_FAIL=str(int(ps_fail)),
                       TEST_INSPECT_FAIL=str(int(inspect_fail)), TEST_SOURCE=str(source))
            shell = '''set -euo pipefail
log() { :; }
die() { echo "$*" >&2; exit 1; }
docker() {
  case "$1" in
    ps) [ "$TEST_PS_FAIL" = 0 ] || return 1; echo abc ;;
    inspect) [ "$TEST_INSPECT_FAIL" = 0 ] || return 1; printf '%s' "$TEST_CONTAINERS" ;;
  esac
}
datasets="test|$TEST_SOURCE"
'''
            return subprocess.run(['bash', '-c', shell + CHECKS + '\n' + body],
                                  env=env, capture_output=True, text=True, timeout=10)

    @staticmethod
    def container(mount=None, service='unrelated', running=True):
        return {'Name': '/test-container', 'State': {'Running': running},
                'Config': {'Labels': {'com.docker.compose.service': service}},
                'Mounts': [] if mount is None else [{'Source': mount}]}

    def test_stopped_sources_pass(self):
        self.assertEqual(self.check([self.container('SOURCE', running=False)]).returncode, 0)

    def test_unrelated_container_passes(self):
        self.assertEqual(self.check([self.container('SOURCE-other')]).returncode, 0)

    def test_related_compose_service_blocks(self):
        result = self.check([self.container(service='clickhouse')])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stop source containers', result.stderr)

    def test_renamed_container_mount_overlap_blocks(self):
        for mount in ('SOURCE', 'SOURCE/child'):
            with self.subTest(mount=mount):
                self.assertNotEqual(self.check([self.container(mount)]).returncode, 0)
        result = self.check([self.container('/')])
        self.assertNotEqual(result.returncode, 0)

    def test_docker_errors_block(self):
        self.assertNotEqual(self.check([], ps_fail=True).returncode, 0)
        self.assertNotEqual(self.check([], inspect_fail=True).returncode, 0)

    def test_malformed_inspect_blocks(self):
        self.assertNotEqual(self.check({'unexpected': 'object'}).returncode, 0)

    def test_no_running_containers_passes(self):
        result = self.check([], 'docker() { :; }; assert_source_containers_stopped')
        self.assertEqual(result.returncode, 0, result.stderr)



if __name__ == '__main__':
    unittest.main()
