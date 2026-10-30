"""Offline checks for archiver discovery, including Xcode-only CI failures."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class ArchiverDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="discobox-build-tools-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin))
        self.env.pop("GHOSTTY_LLVM_LIBTOOL", None)
        self.resolver = Path(__file__).resolve().parent / "find-llvm-libtool.sh"
        self.tool(self.bin / "xcrun", "exit 72")

    def tool(self, path, body="exit 0"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return path

    def resolve(self):
        return subprocess.run(
            ["/bin/bash", str(self.resolver)], env=self.env,
            capture_output=True, text=True, check=False,
        )

    def test_homebrew_tool_is_found_when_xcode_does_not_supply_it(self):
        prefix = self.root / "Homebrew LLVM 20"
        archiver = self.tool(prefix / "bin/llvm-libtool-darwin")
        self.tool(self.bin / "brew", "printf '%s\\n' " + shlex.quote(str(prefix)))
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(archiver))

    def test_explicit_archiver_takes_precedence_over_path(self):
        archiver = self.tool(self.root / "Explicit LLVM/bin/llvm-libtool-darwin")
        self.tool(self.bin / "llvm-libtool-darwin")
        self.env["GHOSTTY_LLVM_LIBTOOL"] = str(archiver)
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(archiver))

    def test_invalid_override_reports_an_error_without_falling_back(self):
        self.tool(self.bin / "llvm-libtool-darwin")
        self.env["GHOSTTY_LLVM_LIBTOOL"] = str(self.root / "missing")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("executable absolute path", result.stderr)

    def test_path_tool_is_found(self):
        archiver = self.tool(self.bin / "llvm-libtool-darwin")
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(archiver))

    def test_xcode_tool_is_found(self):
        archiver = self.tool(self.root / "Xcode Toolchain/llvm-libtool-darwin")
        self.tool(self.bin / "xcrun", "printf '%s\\n' " + shlex.quote(str(archiver)))
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(archiver))

    def test_missing_tool_explains_how_to_install_it(self):
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("brew install llvm@20", result.stderr)


if __name__ == "__main__":
    unittest.main()
