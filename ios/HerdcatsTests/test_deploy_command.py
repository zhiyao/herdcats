"""Deployment guards run without GitHub, Apple credentials, or uploads."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/deploy-release.py'
spec = importlib.util.spec_from_file_location('deploy_release', SCRIPT)
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
SHA = 'a' * 40


class DeployTests(unittest.TestCase):
    def pr(self, **changes):
        return dict(state='MERGED', baseRefName='main', headRefName='release/1.0.0',
                    mergeCommit={'oid': SHA}, **changes)

    def test_unmerged_wrong_base_and_nonrelease_pr_rejected(self):
        for key, value in [('state', 'OPEN'), ('baseRefName', 'other'),
                           ('headRefName', 'feature')]:
            pr = self.pr()
            pr[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                deploy.validate_pr(pr)
        self.assertEqual(deploy.validate_pr(self.pr()), SHA)

    def test_ci_requires_exact_sha_successful_main_push(self):
        good = dict(headSha=SHA, event='push', status='completed', conclusion='success')
        deploy.validate_ci([good], SHA)
        for key, value in [('headSha', 'b' * 40), ('event', 'pull_request'),
                           ('status', 'in_progress'), ('conclusion', 'failure'),
                           ('conclusion', 'cancelled')]:
            bad = dict(good, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                deploy.validate_ci([bad], SHA)
        with self.assertRaises(RuntimeError):
            deploy.validate_ci([], SHA)
        with self.assertRaises(RuntimeError):
            deploy.validate_ci([dict(good, conclusion='failure'), good], SHA)

    def test_prepare_creates_reviewed_notes_before_bump_and_pr(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ios/fastlane').mkdir(parents=True)
            calls = []
            def fake_git(*args, **kwargs):
                calls.append(args)
                if args[:2] == ('branch', '--show-current'):
                    return 'main'
                if args[:2] == ('tag', '--merged'):
                    return 'herdrcat-v0.8.0'
                return ''
            def fake_run(*args, **kwargs):
                calls.append(args)
                if args[0] == str(root / 'ios/bin/changelog'):
                    self.assertEqual(args[1], '0.8.0')
                    (root / 'ios/fastlane/changelog.txt').write_text('New feature\n')
                if args[0] == str(root / 'ios/bin/release'):
                    self.assertTrue(any(c[:2] == ('commit', '-m') for c in calls))
                if args[:3] == ('gh', 'pr', 'list'):
                    return '[]'
            with patch.object(deploy, 'ROOT', root), patch.object(deploy, 'clean'), \
                 patch.object(deploy, 'version_at', return_value='0.8.0'), \
                 patch.object(deploy, 'confirm'), patch.dict(deploy.os.environ, EDITOR=''), \
                 patch.object(deploy, 'git', side_effect=fake_git), \
                 patch.object(deploy, 'run', side_effect=fake_run):
                deploy.prepare('0.9.0')
            self.assertEqual((root / 'ios/releases/0.9.0.txt').read_text(), 'New feature\n')
            self.assertIn(('switch', '-c', 'release/0.9.0', 'origin/main'), calls)
            self.assertTrue(any(c[:3] == ('gh', 'pr', 'create') for c in calls))

    def test_prepared_branch_retry_does_not_bump_or_duplicate_pr(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            notes = root / 'ios/releases/1.0.0.txt'
            notes.parent.mkdir(parents=True)
            notes.write_text('Reviewed notes')
            def fake_git(*args, **kwargs):
                if args[:2] == ('branch', '--show-current'):
                    return 'release/1.0.0'
                if args[:1] == ('merge-base',):
                    return 'base'
                return SHA
            with patch.object(deploy, 'ROOT', root), patch.object(deploy, 'clean'), \
                 patch.object(deploy, 'version_at', return_value='1.0.0'), \
                 patch.object(deploy, 'confirm'), patch.object(deploy, 'git', side_effect=fake_git), \
                 patch.object(deploy, 'run', return_value='[{"url":"https://example.invalid/pr/1"}]') as run:
                deploy.prepare('1.0.0')
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[:3], ('gh', 'pr', 'list'))

    def test_failed_ci_never_creates_checkout_or_uploads(self):
        import json
        with patch.dict(deploy.os.environ, DEVELOPMENT_TEAM='ABCDEFGHIJ'), \
             patch.object(deploy, 'clean'), patch.object(deploy, 'git') as git, \
             patch.object(deploy, 'run', side_effect=[json.dumps(self.pr()), '[]']) as run:
            with self.assertRaises(RuntimeError):
                deploy.publish('42')
            self.assertFalse(any(call.args[:2] == ('worktree', 'add') for call in git.call_args_list))
            self.assertEqual(run.call_count, 2)

    def test_publish_uses_merged_notes_exact_sha_and_cleans_failed_upload(self):
        import json
        good = dict(headSha=SHA, event='push', status='completed', conclusion='success')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            checkout = root / 'source'
            def fake_git(*args, **kwargs):
                if args[:2] == ('worktree', 'add'):
                    (checkout / 'ios/fastlane').mkdir(parents=True)
                if args[:1] == ('show',):
                    return 'Reviewed release notes'
            def fake_run(*args, **kwargs):
                if args[:3] == ('gh', 'pr', 'view'):
                    return json.dumps(self.pr())
                if args[:3] == ('gh', 'run', 'list'):
                    return json.dumps([good])
                self.assertEqual(args, (str(checkout / 'ios/bin/beta'),))
                self.assertEqual((checkout / 'ios/fastlane/changelog.txt').read_text(),
                                 'Reviewed release notes\n')
                raise RuntimeError('upload failed')
            with patch.dict(deploy.os.environ, DEVELOPMENT_TEAM='ABCDEFGHIJ'), \
                 patch.object(deploy, 'clean'), patch.object(deploy, 'confirm'), \
                 patch.object(deploy, 'version_at', return_value='1.0.0'), \
                 patch.object(deploy.tempfile, 'mkdtemp', return_value=temp), \
                 patch.object(deploy, 'git', side_effect=fake_git) as git, \
                 patch.object(deploy, 'run', side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, 'upload failed'):
                    deploy.publish('42')
                git.assert_any_call('worktree', 'add', '--detach', str(checkout), SHA)
                git.assert_any_call('worktree', 'remove', '--force', str(checkout))


if __name__ == '__main__':
    unittest.main(verbosity=2)
