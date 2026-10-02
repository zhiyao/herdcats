#!/usr/bin/env python3
"""Behavioral checks for the production attachment-directory shell builder."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONNECTION_SWIFT = ROOT / "ios/Herdcats/Networking/HerdrConnection+Remote.swift"


class AttachmentStorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        source = CONNECTION_SWIFT.read_text()
        octal_start = source.index("    static func printfOctal(")
        octal_end = source.index("\n    }", octal_start) + len("\n    }")
        script_start = source.index("    static func attachmentDirectoryPreparationScript", octal_start)
        script_end = source.index("    static func sanitizedAttachmentExtension", script_start)
        production_functions = (
            source[octal_start:octal_end]
            + "\n"
            + source[script_start:script_end]
        )
        swift_harness = f"""import Foundation

struct AttachmentScriptBuilder {{
{production_functions}
}}

@main
struct Main {{
    static func main() {{
        print(AttachmentScriptBuilder.attachmentDirectoryPreparationScript(directory: CommandLine.arguments[1]), terminator: "")
    }}
}}
"""
        cls.build_dir = tempfile.TemporaryDirectory(prefix="herdrcat-attachment-swift-")
        build_path = Path(cls.build_dir.name)
        swift_file = build_path / "AttachmentScriptBuilder.swift"
        cls.builder = build_path / "attachment-script"
        swift_file.write_text(swift_harness)
        subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                "-module-cache-path",
                str(build_path / "module-cache"),
                str(swift_file),
                "-o",
                str(cls.builder),
            ],
            check=True,
            cwd=ROOT,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build_dir.cleanup()

    def run_preparation(self, attachments: Path, succeeds: bool = True) -> subprocess.CompletedProcess[str]:
        script = subprocess.run(
            [str(self.builder), str(attachments)],
            check=True,
            text=True,
            capture_output=True,
        ).stdout
        result = subprocess.run(["/bin/sh", "-c", script], text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stderr)
        return result

    def paths(self, root: Path) -> tuple[Path, Path, Path]:
        cache = root / ".cache"
        app = cache / "herdrcat"
        attachments = app / "attachments"
        return cache, app, attachments

    def test_fresh_directories_are_private_and_existing_cache_mode_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory(prefix="herdrcat-fresh-") as temp:
            root = Path(temp)
            cache, app, attachments = self.paths(root)
            self.run_preparation(attachments)
            self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
            self.assertEqual(app.stat().st_mode & 0o777, 0o700)
            self.assertEqual(attachments.stat().st_mode & 0o777, 0o700)

            for path in (app, attachments):
                path.chmod(0o755)
            cache.chmod(0o751)
            self.run_preparation(attachments)
            self.assertEqual(cache.stat().st_mode & 0o777, 0o751)
            self.assertEqual(app.stat().st_mode & 0o777, 0o700)
            self.assertEqual(attachments.stat().st_mode & 0o777, 0o700)

    def test_rejects_live_and_dangling_symlinks_at_each_path_component(self) -> None:
        for component in (".cache", "herdrcat", "attachments"):
            for dangling in (False, True):
                with self.subTest(component=component, dangling=dangling), tempfile.TemporaryDirectory(
                    prefix="herdrcat-symlink-"
                ) as temp:
                    root = Path(temp)
                    cache, app, attachments = self.paths(root / "home")
                    attachments.mkdir(parents=True)
                    target = root / "external-target"
                    target_path = {
                        ".cache": target,
                        "herdrcat": target / "app-dir",
                        "attachments": target / "attachments-dir",
                    }[component]
                    if not dangling:
                        if component == ".cache":
                            target_leaf = target_path / "herdrcat/attachments"
                        elif component == "herdrcat":
                            target_leaf = target_path / "attachments"
                        else:
                            target_leaf = target_path
                        target_leaf.mkdir(parents=True)
                        target_leaf.chmod(0o755)
                        sentinel = target_leaf / "sentinel"
                        sentinel.write_text("must remain untouched")
                    link = {".cache": cache, "herdrcat": app, "attachments": attachments}[component]
                    shutil.rmtree(link)
                    link.symlink_to(target_path, target_is_directory=True)
                    self.run_preparation(attachments, succeeds=False)
                    if dangling:
                        self.assertFalse(target_path.exists())
                    else:
                        self.assertEqual(target_leaf.stat().st_mode & 0o777, 0o755)
                        self.assertEqual(sentinel.read_text(), "must remain untouched")

    def test_shell_metacharacters_in_directory_are_literal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="herdrcat-meta-") as temp:
            home = Path(temp) / "home ' quoted $() ;\nname"
            home.mkdir()
            _, _, attachments = self.paths(home)
            self.run_preparation(attachments)
            self.assertTrue(attachments.is_dir())

    def test_repository_gitignore_is_left_untouched(self) -> None:
        with tempfile.TemporaryDirectory(prefix="herdrcat-repo-attach-") as temp:
            root = Path(temp)
            repository = root / "repository"
            repository.mkdir()
            victim = root / "victim-gitignore"
            victim.write_text("existing ignore rules\n")
            herdrcat = repository / ".herdrcat"
            herdrcat.mkdir()
            gitignore = herdrcat / ".gitignore"
            gitignore.symlink_to(victim)
            before = victim.read_bytes()
            _, _, attachments = self.paths(root / "remote-home")
            attachments.parents[1].mkdir(parents=True)
            self.run_preparation(attachments)
            self.assertTrue(gitignore.is_symlink())
            self.assertEqual(victim.read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
