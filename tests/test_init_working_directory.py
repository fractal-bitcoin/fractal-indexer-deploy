"""Verify initialization accepts only the corresponding service directory."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class InitWorkingDirectoryTests(unittest.TestCase):
    def check_init(self, service, args=(), correct_directory=True):
        with tempfile.TemporaryDirectory(prefix='init cwd test ') as directory:
            base = Path(directory).resolve()
            service_dir = base / service
            scripts = service_dir / 'scripts'
            scripts.mkdir(parents=True)
            shutil.copyfile(REPO / service / 'scripts/init.sh', scripts / 'init.sh')
            if service == 'fractald':
                (service_dir / 'conf').mkdir()
                shutil.copyfile(REPO / service / 'conf/bitcoin.conf.example',
                                service_dir / 'conf/bitcoin.conf.example')
            caller = base / 'unrelated directory'
            (caller / 'data').mkdir(parents=True)
            sentinel = caller / 'data/keep'
            sentinel.write_text('unchanged')
            commands = base / 'bin'
            commands.mkdir()
            log = base / 'commands.log'
            # Mock external side effects; mkdir/cp execute only in the fixture.
            for name in ('docker', 'sudo'):
                command = commands / name
                command.write_text('#!/bin/bash\nprintf "%s|%s|%s\\n" "$PWD" "${0##*/}" "$*" >> "$TEST_COMMAND_LOG"\n')
                command.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
                       TEST_COMMAND_LOG=str(log))
            result = subprocess.run(['bash', str(scripts / 'init.sh'), *args],
                                    cwd=service_dir if correct_directory else caller, env=env, capture_output=True,
                                    text=True, timeout=10)
            if not correct_directory:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('First run: cd', result.stderr)
                self.assertFalse(log.exists(), 'must reject before Docker or sudo')
                self.assertFalse((service_dir / 'data').exists())
                self.assertEqual(sentinel.read_text(), 'unchanged')
                self.assertEqual(sorted(p.name for p in caller.iterdir()), ['data'])
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text().splitlines()
            self.assertTrue(calls)
            self.assertTrue(all(call.startswith(str(service_dir) + '|') for call in calls), calls)
            self.assertTrue((service_dir / 'data').is_dir())
            self.assertEqual(sentinel.read_text(), 'unchanged')
            self.assertEqual(sorted(p.name for p in caller.iterdir()), ['data'])
            if service == 'fractald':
                self.assertTrue((service_dir / 'conf/bitcoin.conf').is_file())
            if service == 'fractal-indexer':
                self.assertTrue((service_dir / 'data/clickhouse').is_dir())
                self.assertTrue((service_dir / 'logs/pika').is_dir())
            if args == ('db',):
                self.assertTrue(any('|docker|compose run --rm indexer -full -end 256' in call
                                    for call in calls), calls)

    def test_each_service_from_correct_directory(self):
        for service in ('fractald', 'fractal-indexer', 'proof-publisher'):
            with self.subTest(service=service):
                self.check_init(service)

    def test_each_service_rejects_unrelated_directory(self):
        for service in ('fractald', 'fractal-indexer', 'proof-publisher'):
            with self.subTest(service=service):
                self.check_init(service, correct_directory=False)

    def test_database_initialization_rejects_unrelated_directory(self):
        self.check_init('fractal-indexer', ('db',), correct_directory=False)

    def test_database_initialization_uses_service_directory(self):
        self.check_init('fractal-indexer', ('db',))


if __name__ == '__main__':
    unittest.main()
