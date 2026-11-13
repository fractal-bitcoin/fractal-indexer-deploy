"""Verify RPC credentials round-trip through generated YAML scalars."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
CASES = [
    ('fip101', '0123456789abcdef'),
    ('user"name', 'pass"word'),
    ('user\\name', r'password\n\t\u0041\\end'),
    ('user', 'colon: hash# & slash/ single\' quote"'),
    ('用户', '口令 ☃'),
    ('user\tname', 'line1\nline2\r\tend'),
    ('{REPLACE_RPC_PASSWORD}', '{REPLACE_RPC_USER}'),
    ('user', '\"\nextra_key: true\n#'),
    ('', ''),
]


class ChainConfigCredentialTests(unittest.TestCase):
    def generate(self, user, password):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'fractal-indexer/conf/indexer'
            config.mkdir(parents=True)
            shutil.copyfile(REPO / 'fractal-indexer/conf/indexer/chain.yaml.example',
                            config / 'chain.yaml.example')
            env = dict(os.environ, TEST_LIB=str(REPO / 'scripts/lib.sh'),
                       TEST_ROOT=directory, TEST_USER=user, TEST_PASSWORD=password)
            result = subprocess.run(['bash', '-c', '''set -euo pipefail
. "$TEST_LIB"
REPO_ROOT="$TEST_ROOT"
generate_fractal_indexer_chain_config "$TEST_USER" "$TEST_PASSWORD"
'''], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return (config / 'chain.yaml').read_text()

    def test_credential_values_round_trip(self):
        template = (REPO / 'fractal-indexer/conf/indexer/chain.yaml.example').read_text()
        for user, password in CASES:
            with self.subTest(user=user, password=password):
                generated = self.generate(user, password)
                match = re.search(r'^rpc_auth: (.+) # user:password$', generated, re.MULTILINE)
                self.assertIsNotNone(match)
                self.assertEqual(json.loads(match.group(1)), user + ':' + password)
                # Serialization must affect only the intended scalar, not the
                # rest of the document or credentials containing placeholders.
                self.assertEqual(re.sub(r'^rpc_auth: .*$', '', generated, flags=re.MULTILINE),
                                 re.sub(r'^rpc_auth: .*$', '', template, flags=re.MULTILINE))

    @unittest.skipUnless(shutil.which('ruby'), 'optional full YAML check requires Ruby/Psych')
    def test_full_yaml_parses_with_original_values(self):
        for user, password in CASES:
            with self.subTest(user=user, password=password):
                generated = self.generate(user, password)
                result = subprocess.run(['ruby', '-rjson', '-ryaml', '-e',
                                         'puts JSON.generate(YAML.safe_load(STDIN.read))'],
                                        input=generated, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                document = json.loads(result.stdout)
                self.assertEqual(document['rpc_auth'], user + ':' + password)
                self.assertEqual(document['rpc'], 'http://fractald:10332')
                self.assertNotIn('extra_key', document)


if __name__ == '__main__':
    unittest.main()
