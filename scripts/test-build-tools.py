"""Offline checks for archiver discovery, including Xcode-only CI failures."""

import os
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
import sys
import zipfile


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


class PinnedDependencyFetchTests(unittest.TestCase):
    package_hash = "zg-0.13.4-AAAAAGiZ7QLz4pvECFa_wG4O4TP4FLABHHbemH2KakWM"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="discobox-dependency-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.cache = self.root / "cache"
        self.env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin",
                        ZIG_GLOBAL_CACHE_DIR=str(self.cache))
        self.fetcher = Path(__file__).resolve().parent / "fetch-ghostty-deps.sh"
        self.tool("curl", 'while [ "$#" -gt 0 ]; do if [ "$1" = --output ]; then printf fixture > "$2"; exit 0; fi; shift; done; exit 1')
        self.tool("zig", "printf '%s\\n' " + shlex.quote(self.package_hash))

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def fetch(self):
        return subprocess.run(["/bin/bash", str(self.fetcher)], env=self.env,
                              capture_output=True, text=True, check=False)

    def test_matching_upstream_hash_is_accepted_and_download_cleaned_up(self):
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified zg package hash", result.stdout)
        self.assertEqual(list((self.cache / "downloads").iterdir()), [])

    def test_changed_package_contents_fail_closed(self):
        self.tool("zig", "printf 'unexpected-package-hash\\n'")
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hash mismatch", result.stderr)
        self.assertEqual(list((self.cache / "downloads").iterdir()), [])

    def test_failed_download_is_not_accepted(self):
        self.tool("curl", "exit 22")
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Verified zg package hash", result.stdout)

    def test_cached_package_does_not_download_again(self):
        (self.cache / "p" / self.package_hash).mkdir(parents=True)
        self.tool("curl", "exit 99")
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


class PreviewPublishingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="discobox-release-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.notes = self.root / "notes.txt"
        self.archive = self.root / "path with spaces" / "Discobox-macos-arm64.zip"
        self.archive.parent.mkdir()
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Discobox.app/Contents/Info.plist", "fixture")
            archive.writestr("Discobox.app/Contents/MacOS/DiscoboxDesktop", "fixture")
        self.env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin",
                        GH_REPO="example/discobox-ui", RELEASE_TAG="v0.1.0",
                        RELEASE_COMMIT="a" * 40, FIXTURE_CALLS=str(self.calls),
                        FIXTURE_NOTES=str(self.notes), FIXTURE_RELEASE_EXISTS="1")
        self.env.pop("GH_TOKEN", None)
        self.env.pop("GITHUB_TOKEN", None)
        gh = self.bin / "gh"
        gh.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["FIXTURE_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["release", "view"]:
    sys.exit(0 if os.environ["FIXTURE_RELEASE_EXISTS"] == "1" else 1)
if "--notes-file" in args:
    pathlib.Path(os.environ["FIXTURE_NOTES"]).write_text(pathlib.Path(args[args.index("--notes-file") + 1]).read_text())
''')
        gh.chmod(0o755)
        self.script = Path(__file__).resolve().parent / "publish-preview.sh"

    def publish(self):
        return subprocess.run(["/bin/bash", str(self.script), str(self.archive)],
                              env=self.env, capture_output=True, text=True, check=False)

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_existing_release_receives_exact_zip_and_matching_checksum_only(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[1], ["release", "upload", "v0.1.0", str(self.archive),
                                     str(self.archive) + ".sha256", "--repo", "example/discobox-ui", "--clobber"])
        checksum = Path(str(self.archive) + ".sha256").read_text().strip()
        expected = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertEqual(checksum, expected + "  Discobox-macos-arm64.zip")
        self.assertFalse(self.notes.exists())

    def test_missing_release_is_created_as_preview_of_existing_tag(self):
        self.env["FIXTURE_RELEASE_EXISTS"] = "0"
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        command = self.commands()[1]
        self.assertEqual(command[:3], ["release", "create", "v0.1.0"])
        for flag in ["--verify-tag", "--prerelease", "--latest=false"]:
            self.assertIn(flag, command)
        notes = self.notes.read_text()
        self.assertIn("Preview software", notes)
        self.assertIn("a" * 40, notes)
        self.assertIn("not notarized", notes)
        self.assertIn("discobox-ai/discobox#getting-started", notes)

    def test_invalid_zip_never_contacts_github(self):
        self.archive.write_bytes(b"not a ZIP")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_source_archive_is_not_published_as_app(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("README.md", "source archive")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_branch_name_is_not_used_as_release_tag(self):
        self.env["RELEASE_TAG"] = "main"
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()
