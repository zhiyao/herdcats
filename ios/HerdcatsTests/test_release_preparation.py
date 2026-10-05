"""Release helpers must preserve build numbers and use the protected PR flow."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class ReleasePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='herdcats-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios/bin').mkdir(parents=True)
        (self.root / 'tools').mkdir()
        for name in ['release', 'deploy', 'next-version']:
            shutil.copy2(PROJECT / 'ios/bin' / name, self.root / 'ios/bin' / name)
        generator = self.root / 'tools/xcodegen'
        generator.write_text('#!/bin/sh\necho Generated\n')
        generator.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'tools'}:{os.environ['PATH']}")
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release-test@example.invalid')
        self.git('config', 'core.hooksPath', str(self.root / 'no-hooks'))
        self.set_build('84')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def set_build(self, build):
        (self.root / 'ios/project.yml').write_text(
            f'properties:\n  CFBundleShortVersionString: "0.3.1"\n  CFBundleVersion: "{build}"\n')

    def run_helper(self, name, *args, input=None):
        return subprocess.run(['bash', str(self.root / 'ios/bin' / name), *args],
                              cwd=self.root, env=self.env, input=input,
                              text=True, capture_output=True)

    def test_private_history_build_floor_is_preserved_without_tagging(self):
        self.git('switch', '-c', 'release/0.3.2')
        result = self.run_helper('release', '0.3.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CFBundleVersion: "85"', (self.root / 'ios/project.yml').read_text())
        self.assertIn('CFBundleShortVersionString: "0.3.2"', (self.root / 'ios/project.yml').read_text())
        self.assertEqual(self.git('tag', '--list'), '')
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_higher_commit_count_is_used(self):
        self.set_build('1')
        self.git('add', '.')
        self.git('commit', '-m', 'lower fixture build')
        self.git('commit', '--allow-empty', '-m', 'additional fixture commit')
        self.git('switch', '-c', 'release/0.3.2')
        result = self.run_helper('release', '0.3.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CFBundleVersion: "4"', (self.root / 'ios/project.yml').read_text())

    def test_main_is_rejected_before_mutation(self):
        head = self.git('rev-parse', 'HEAD')
        for helper, args in [('release', ['0.3.2']), ('deploy', [])]:
            result = self.run_helper(helper, *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('release branch', result.stderr)
            self.assertEqual(self.git('rev-parse', 'HEAD'), head)
            self.assertEqual(self.git('status', '--porcelain'), '')
            self.assertEqual(self.git('tag', '--list'), '')

    def test_deploy_stops_at_pr_preparation(self):
        self.git('switch', '-c', 'release/0.3.1')
        result = self.run_helper('deploy', input='y\ny\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No tag or upload was created.', result.stdout)
        self.assertEqual(self.git('tag', '--list'), '')
        self.assertIn('CFBundleVersion: "85"', (self.root / 'ios/project.yml').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
