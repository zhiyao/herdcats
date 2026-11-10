import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def reject_duplicates(pairs):
    keys = [key for key, _ in pairs]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        raise ValueError(f"duplicate JSON keys: {duplicates}")
    return dict(pairs)


class ContractFilesTest(unittest.TestCase):
    def test_contract_files_have_no_duplicate_keys(self):
        # A repeated key silently drops one description when the file is parsed.
        for name in ("protocol.json", "validation.json", "setup.json"):
            with self.subTest(name=name):
                json.loads((ROOT / name).read_text(), object_pairs_hook=reject_duplicates)

    def test_cursor_contract_is_documented(self):
        protocol = json.loads((ROOT / "protocol.json").read_text())
        self.assertIn("cursor_cli", protocol)
        self.assertIn("--cursor-root", protocol["launch"]["flags"])
        methods = [request["method"] for request in protocol["requests"]]
        self.assertIn("prompt.submit", methods)
        self.assertIn("cursor_prompts", protocol["capabilities"])

    def test_pi_extension_install_is_documented(self):
        protocol = json.loads((ROOT / "protocol.json").read_text())
        self.assertIn("pi_extension_install", protocol["capabilities"])
        self.assertIn("herdcats-bridge pi-extension status|install [--pi-agent-dir PATH]", protocol["subcommands"])
        self.assertIn("pi-extension install", protocol["pi"]["distribution"])


if __name__ == "__main__":
    unittest.main()
