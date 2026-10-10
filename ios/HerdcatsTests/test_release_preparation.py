"""Release helpers: PR prepare, then tag/publish after merge."""
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
        for name in ['release', 'deploy', 'next-version', 'changelog', 'beta']:
            src = PROJECT / 'ios/bin' / name
            if src.exists():
                shutil.copy2(src, self.root / 'ios/bin' / name)
        # Stub tools ahead of real PATH entries.
        for name, body in {
            'xcodegen': '#!/bin/sh\necho Generated\n',
            'changelog': '#!/bin/sh\nmkdir -p ios/fastlane\necho "Test notes" > ios/fastlane/changelog.txt\necho stub-changelog\n',
            'beta': '#!/bin/sh\necho stub-beta\n',
        }.items():
            path = self.root / 'tools' / name
            path.write_text(body)
            path.chmod(0o755)
        # Prefer stub changelog/beta over copied ios/bin ones when deploy looks up BIN_DIR.
        # Deploy invokes "$BIN_DIR/changelog" and "$BIN_DIR/beta"; overwrite those copies with stubs.
        for name in ['changelog', 'beta']:
            path = self.root / 'ios/bin' / name
            path.write_text((self.root / 'tools' / name).read_text())
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'tools'}:{os.environ['PATH']}")
        # Ensure deploy does not find a real `gh` during fixtures.
        self.env['PATH'] = f"{self.root / 'tools'}:{self.env['PATH']}"
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release-test@example.invalid')
        self.git('config', 'core.hooksPath', str(self.root / 'no-hooks'))
        self.set_build('84')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')

    def git(self, *args):
        return subprocess.check_output(
            ['git', '-C', str(self.root), *args], text=True, stderr=subprocess.DEVNULL
        ).strip()

    def set_build(self, build, marketing='0.3.1'):
        (self.root / 'ios/project.yml').write_text(
            f'properties:\n  CFBundleShortVersionString: "{marketing}"\n  CFBundleVersion: "{build}"\n'
        )

    def run_helper(self, name, *args, input=None):
        return subprocess.run(
            ['bash', str(self.root / 'ios/bin' / name), *args],
            cwd=self.root, env=self.env, input=input,
            text=True, capture_output=True,
        )

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

    def test_release_rejects_main_before_mutation(self):
        head = self.git('rev-parse', 'HEAD')
        result = self.run_helper('release', '0.3.2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('release branch', result.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('tag', '--list'), '')

    def test_deploy_usage_without_subcommand(self):
        result = self.run_helper('deploy')
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn('prepare', combined)
        self.assertIn('publish', combined)

    def test_deploy_prepare_creates_branch_bumps_without_tag(self):
        # y = accept suggested 0.3.1, y = proceed, n = skip push (no origin)
        result = self.run_helper('deploy', 'prepare', input='y\ny\nn\n')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git('branch', '--show-current'), 'release/0.3.1')
        self.assertIn('CFBundleVersion: "85"', (self.root / 'ios/project.yml').read_text())
        self.assertEqual(self.git('tag', '--list'), '')
        self.assertIn('bin/deploy publish', result.stdout)

    def test_deploy_publish_rejects_main_ahead_of_origin(self):
        bare = Path(self.temp.name).parent / f'{self.root.name}-origin.git'
        bare.mkdir()
        subprocess.check_call(['git', 'init', '--bare', '-b', 'main', str(bare)])
        self.git('remote', 'add', 'origin', str(bare))
        self.git('push', '-u', 'origin', 'main')
        self.git('commit', '--allow-empty', '-m', 'unpushed on main')
        result = self.run_helper('deploy', 'publish', input='y\n')
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn('ahead of origin/main', combined)
        self.assertEqual(self.git('tag', '--list'), '')

    def test_deploy_publish_tags_on_main_and_runs_beta(self):
        self.git('switch', '-c', 'release/0.3.2')
        self.assertEqual(self.run_helper('release', '0.3.2').returncode, 0)
        self.git('switch', 'main')
        self.git('merge', '--ff-only', 'release/0.3.2')
        # changelog confirm y; beta final confirm is inside stub (no prompts);
        # publish may ask changelog y/e/n then push-tag y/n — answer y, y
        result = self.run_helper('deploy', 'publish', input='y\ny\n')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git('tag', '--list'), 'herdrcat-v0.3.2')
        self.assertIn('stub-changelog', result.stdout)
        self.assertIn('stub-beta', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
