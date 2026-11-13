"""Verify failed config rendering leaves existing files untouched."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'scripts/lib.sh'


class AtomicConfigGenerationTests(unittest.TestCase):
    def render(self, body, *, existing=True, mask='022'):
        with tempfile.TemporaryDirectory(prefix='atomic config ') as directory:
            root = Path(directory)
            template = root / 'template'
            template.write_text('value=PLACEHOLDER\n')
            target = root / 'config'
            if existing:
                target.write_text('original\n')
                target.chmod(0o640)
            env = dict(os.environ, TEST_LIB=str(LIB), TEST_TEMPLATE=str(template),
                       TEST_TARGET=str(target))
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\n. "$TEST_LIB"\numask ' + mask + '\n' + body],
                                    env=env, capture_output=True, text=True, timeout=10)
            return (result, target.read_text() if target.exists() else None,
                    stat.S_IMODE(target.stat().st_mode) if target.exists() else None,
                    list(root.glob('config.tmp.*')))

    def test_success_replaces_content_and_preserves_mode(self):
        result, content, mode, leftovers = self.render(
            'generate_from_template "$TEST_TEMPLATE" "$TEST_TARGET" PLACEHOLDER updated')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(content, 'value=updated\n')
        self.assertEqual(mode, 0o640)
        self.assertEqual(leftovers, [])

    def test_partial_sed_failure_preserves_original(self):
        result, content, mode, leftovers = self.render('''sed() { printf partial; return 1; }
render_template_atomically "$TEST_TEMPLATE" "$TEST_TARGET" -e ""''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(content, 'original\n')
        self.assertEqual(mode, 0o640)
        self.assertEqual(leftovers, [])

    def test_failure_does_not_create_formal_target(self):
        result, content, mode, leftovers = self.render('''sed() { printf partial; return 1; }
render_template_atomically "$TEST_TEMPLATE" "$TEST_TARGET" -e ""''', existing=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(content)
        self.assertEqual(leftovers, [])

    def test_failed_rename_preserves_original(self):
        result, content, mode, leftovers = self.render('''mv() { return 1; }
render_template_atomically "$TEST_TEMPLATE" "$TEST_TARGET" -e ""''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(content, 'original\n')
        self.assertEqual(leftovers, [])

    def test_new_file_permissions_follow_umask(self):
        for mask, expected in [('022', 0o644), ('077', 0o600)]:
            with self.subTest(mask=mask):
                result, content, mode, leftovers = self.render(
                    'render_template_atomically "$TEST_TEMPLATE" "$TEST_TARGET" -e ""',
                    existing=False, mask=mask)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(mode, expected)
                self.assertEqual(leftovers, [])

    def test_fractald_sed_error_preserves_existing_config(self):
        body = '''REPO_ROOT="$(dirname "$TEST_TARGET")"
mkdir -p "$REPO_ROOT/fractald/conf"
cp "$TEST_TEMPLATE" "$REPO_ROOT/fractald/conf/bitcoin.conf.example"
printf original > "$REPO_ROOT/fractald/conf/bitcoin.conf"
if generate_fractald_config user $'line1\\nline2' 0; then exit 1; fi
[ "$(cat "$REPO_ROOT/fractald/conf/bitcoin.conf")" = original ]
[ -z "$(find "$REPO_ROOT/fractald/conf" -name '*.tmp.*' -print)" ]
'''
        result, _, _, _ = self.render(body)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
