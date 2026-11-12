"""Exercise credential isolation without connecting to a repository."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'scripts/lib.sh'


class KopiaCredentialTests(unittest.TestCase):
    def run_shell(self, body, overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('AWS_', 'KOPIA_'))}
            env.update(AWS_ACCESS_KEY_ID='unrelated-id',
                       AWS_SECRET_ACCESS_KEY='unrelated-secret',
                       AWS_SESSION_TOKEN='unrelated-token',
                       KOPIA_CACHE_DIRECTORY=directory, TEST_LIB=str(LIB))
            env.update(overrides or {})
            # The function replaces only the Kopia executable. No network or
            # real credential/config storage is accessed by these tests.
            shell = '''set -euo pipefail
. "$TEST_LIB"
kopia() {
  [ "$AWS_ACCESS_KEY_ID" = "$KOPIA_R2_ACCESS_KEY_ID" ]
  [ "$AWS_SECRET_ACCESS_KEY" = "$KOPIA_R2_SECRET_ACCESS_KEY" ]
  [ -z "${AWS_SESSION_TOKEN:-}" ]
  [ "$KOPIA_CHECK_FOR_UPDATES" = false ]
}
'''
            return subprocess.run(['bash', '-c', shell + body], env=env,
                                  capture_output=True, text=True, timeout=10)

    def test_defaults_ignore_generic_aws_credentials(self):
        result = self.run_shell('''load_default_readonly_r2_credentials
[ -n "$KOPIA_R2_ACCESS_KEY_ID" ]
[ -n "$KOPIA_R2_SECRET_ACCESS_KEY" ]
[ "$KOPIA_R2_ACCESS_KEY_ID" != "$AWS_ACCESS_KEY_ID" ]
[ "$KOPIA_R2_SECRET_ACCESS_KEY" != "$AWS_SECRET_ACCESS_KEY" ]
kopia_connect_s3 readonly
[ "$AWS_ACCESS_KEY_ID" = unrelated-id ]
[ "$AWS_SECRET_ACCESS_KEY" = unrelated-secret ]
[ "$AWS_SESSION_TOKEN" = unrelated-token ]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_custom_pair_is_preserved_in_both_modes(self):
        result = self.run_shell('''load_default_readonly_r2_credentials
[ "$KOPIA_R2_ACCESS_KEY_ID" = custom-id ]
[ "$KOPIA_R2_SECRET_ACCESS_KEY" = custom-secret ]
kopia_connect_s3 readonly
kopia_connect_s3
[ "$AWS_SESSION_TOKEN" = unrelated-token ]
''', {'KOPIA_R2_ACCESS_KEY_ID': 'custom-id',
      'KOPIA_R2_SECRET_ACCESS_KEY': 'custom-secret'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_partial_override_rejected(self):
        for name in ('KOPIA_R2_ACCESS_KEY_ID', 'KOPIA_R2_SECRET_ACCESS_KEY'):
            with self.subTest(name=name):
                result = self.run_shell('load_default_readonly_r2_credentials', {name: 'custom'})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('missing required environment variable: KOPIA_R2_', result.stderr)

    def test_upload_connection_rejects_generic_credentials_only(self):
        result = self.run_shell('kopia_connect_s3')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing required environment variable: KOPIA_R2_ACCESS_KEY_ID', result.stderr)


if __name__ == '__main__':
    unittest.main()
