"""Test curl dependency handling without running a package manager."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
TEXT = (REPO / 'scripts/install-deps.sh').read_text()
# Exercise the installer after its CLI/root checks with mocked commands.
INSTALLER = TEXT[TEXT.index('detect_package_manager() {'):]


class InstallDepsTests(unittest.TestCase):
    def run_installer(self, package_manager='apt-get', installed=False, install_succeeds=True):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'curl-installed'
            if installed:
                marker.touch()
            env = dict(os.environ, TEST_LIB=str(REPO / 'scripts/lib.sh'),
                       TEST_PM=package_manager, TEST_MARKER=str(marker),
                       TEST_SUCCESS=str(int(install_succeeds)))
            shell = '''set -euo pipefail
. "$TEST_LIB"
command() {
  if [ "${1:-}" = -v ]; then
    case "$2" in
      curl) [ -f "$TEST_MARKER" ]; return ;;
      docker|jq|kopia|rsync|lsof) return 0 ;;
      apt-get|dnf|yum) [ "$2" = "$TEST_PM" ]; return ;;
      systemctl) return 1 ;;
    esac
  fi
  builtin command "$@"
}
docker() { :; }
mock_install() {
  printf 'MOCK-PACKAGES: %s\\n' "$*"
  if [ "${1:-}" = install ] && [ "$TEST_SUCCESS" = 1 ]; then
    : > "$TEST_MARKER"
  fi
}
apt-get() { mock_install "$@"; }
dnf() { mock_install "$@"; }
yum() { mock_install "$@"; }
'''
            return subprocess.run(['bash', '-c', shell + INSTALLER], env=env,
                                  capture_output=True, text=True, timeout=10)

    def test_only_curl_missing_triggers_install_on_all_managers(self):
        for manager in ('apt-get', 'dnf', 'yum'):
            with self.subTest(manager=manager):
                result = self.run_installer(manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Missing deployment dependencies: curl', result.stdout)
                self.assertIn('MOCK-PACKAGES: install -y ca-certificates curl', result.stdout)

    def test_existing_curl_preserves_early_exit(self):
        result = self.run_installer(installed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('All deployment dependencies are already installed', result.stdout)
        self.assertNotIn('MOCK-PACKAGES', result.stdout)

    def test_curl_still_missing_after_install_fails(self):
        result = self.run_installer(install_succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing required command: curl', result.stderr)


if __name__ == '__main__':
    unittest.main()
