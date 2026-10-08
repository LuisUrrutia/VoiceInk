import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
APPLE = "A" * 40
LOCAL = "B" * 40
OTHER = "C" * 40

TOOL_FIXTURE = """
import json
import os
from pathlib import Path
import sys
import plistlib
import shutil

tool = Path(sys.argv[0]).name
with open(os.environ["VOICEINK_TEST_EVENTS"], "a") as events:
    events.write(json.dumps([tool, *sys.argv[1:]]) + "\\n")
if tool == "security":
    print(os.environ["VOICEINK_TEST_IDENTITIES"])
    sys.exit(int(os.environ["VOICEINK_TEST_SECURITY_STATUS"]))
if tool == "xcodebuild":
    if sys.argv[1:] == ["-version"]:
        print("Xcode 27.0\\nBuild version fixture")
        sys.exit(0)
    status = int(os.environ["VOICEINK_TEST_BUILD_STATUS"])
    if status == 0:
        derived_data = Path(sys.argv[sys.argv.index("-derivedDataPath") + 1])
        app = derived_data / "Build/Products/Release/VoiceInk.app"
        (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.prakashjoshipax.VoiceInk", "CFBundleExecutable": "VoiceInk"}))
        executable = app / "Contents/MacOS/VoiceInk"
        executable.write_text("fixture")
        executable.chmod(0o755)
    sys.exit(status)
if tool == "xcrun":
    print("Apple Swift version 6.4" if "swift" in sys.argv else "/fixture/sdk")
if tool == "codesign":
    print("Identifier=com.prakashjoshipax.VoiceInk")
if tool == "osascript":
    print("[]")
if tool == "ditto":
    shutil.copytree(sys.argv[1], sys.argv[2])
"""


def identity(fingerprint, name, number=1):
    return f'  {number}) {fingerprint} "{name}"'


class LocalSigningTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".tmp/local-signing-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.directory.cleanup)
        self.workspace = Path(self.directory.name)
        self.events_path = self.workspace / "events.jsonl"
        self.bin = self.workspace / "bin"
        self.bin.mkdir()
        for name in ("make", "git"):
            resolved = subprocess.check_output(["xcrun", "--find", "gnumake" if name == "make" else name], text=True).strip()
            (self.bin / name).symlink_to(resolved)
        (self.bin / "python3").symlink_to(sys.executable)
        for name in ("security", "xcodebuild", "xcrun", "codesign", "osascript", "ditto"):
            tool = self.bin / name
            tool.write_text(f"#!{sys.executable}\n{TOOL_FIXTURE}")
            tool.chmod(0o755)
        (self.workspace / "framework").mkdir()
        self.developer = self.workspace / "Xcode.app/Contents/Developer"
        (self.developer / "usr/bin").mkdir(parents=True)
        (self.developer / "usr/bin/xcodebuild").touch()
        (self.workspace / "home/Downloads").mkdir(parents=True)

    def build(self, identities="", override=None, security_status=0, build_status=0):
        environment = os.environ.copy()
        environment.update(
            PATH=f"{self.bin}{os.pathsep}{environment['PATH']}",
            VOICEINK_TEST_EVENTS=str(self.events_path),
            VOICEINK_TEST_IDENTITIES=identities,
            VOICEINK_TEST_SECURITY_STATUS=str(security_status),
            VOICEINK_TEST_BUILD_STATUS=str(build_status),
            DEVELOPER_DIR=str(self.developer),
            HOME=str(self.workspace / "home"),
        )
        command = [
            "make", "--no-print-directory", "-f", str(ROOT / "Makefile"), "local",
            f"LOCAL_DERIVED_DATA={self.workspace / 'build with spaces'}",
            f"DEPS_DIR={self.workspace / 'dependencies'}",
            f"FRAMEWORK_PATH={self.workspace / 'framework'}",
            f"LOCAL_CODESIGN_IDENTITY={override or ''}",
        ]
        self.events_path.write_text("")
        result = subprocess.run(
            command, cwd=self.workspace, env=environment,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30,
        )
        events = [json.loads(line) for line in self.events_path.read_text().splitlines()]
        return result, events

    def assert_signing(self, result, events, fingerprint):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = next(event for event in events if event[0] == "xcodebuild" and "build" in event)
        self.assertIn(f"CODE_SIGN_IDENTITY={fingerprint}", build)
        self.assertIn(f"CODE_SIGNING_REQUIRED={'NO' if fingerprint == '-' else 'YES'}", build)
        self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
        self.assertIn("DEVELOPMENT_TEAM=", build)
        self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD", build)
        self.assertEqual(build[build.index("-configuration") + 1], "Release")
        self.assertTrue(any(event[0] == "ditto" for event in events))
        if fingerprint == "-":
            self.assertIn("permissions may need approval after rebuilds", result.stdout)

    def test_no_identity_uses_ad_hoc(self):
        result, events = self.build("     0 valid identities found")
        self.assert_signing(result, events, "-")

    def test_exact_local_identity_uses_fingerprint(self):
        result, events = self.build(identity(LOCAL, "VoiceInk Local Dev"))
        self.assert_signing(result, events, LOCAL)
        self.assertIn(["security", "find-identity", "-v", "-p", "codesigning"], events)

    def test_similar_and_unrelated_names_are_ignored(self):
        for name in ("VoiceInk Local Dev Backup", "Other VoiceInk Local Dev", "Apple Development", "Developer ID Application: Developer"):
            with self.subTest(name=name):
                result, events = self.build(identity(LOCAL, name))
                self.assert_signing(result, events, "-")

    def test_duplicate_local_fingerprint_is_one_identity(self):
        identities = "\n".join(identity(LOCAL, "VoiceInk Local Dev", i) for i in (1, 2))
        result, events = self.build(identities)
        self.assert_signing(result, events, LOCAL)

    def test_multiple_local_certificates_are_not_chosen_arbitrarily(self):
        identities = "\n".join(identity(key, "VoiceInk Local Dev") for key in (LOCAL, OTHER))
        result, events = self.build(identities)
        self.assert_signing(result, events, "-")
        self.assertIn("Multiple 'VoiceInk Local Dev' identities found", result.stdout)

    def test_unique_apple_identity_remains_preferred(self):
        identities = "\n".join((identity(LOCAL, "VoiceInk Local Dev"), identity(APPLE, "Apple Development: Developer")))
        result, events = self.build(identities)
        self.assert_signing(result, events, APPLE)

    def test_ambiguous_apple_identities_allow_unique_local_certificate(self):
        identities = "\n".join((
            identity(APPLE, "Apple Development: Developer A"),
            identity(OTHER, "Apple Development: Developer B"),
            identity(LOCAL, "VoiceInk Local Dev"),
        ))
        result, events = self.build(identities)
        self.assert_signing(result, events, LOCAL)
        self.assertIn("Multiple 'Apple Development' identities found", result.stdout)

    def test_ambiguous_apple_identities_without_local_use_ad_hoc(self):
        identities = "\n".join(identity(key, "Apple Development: Developer") for key in (APPLE, OTHER))
        result, events = self.build(identities)
        self.assert_signing(result, events, "-")

    def test_duplicate_apple_fingerprint_is_one_identity(self):
        identities = "\n".join(identity(APPLE, "Apple Development: Developer", i) for i in (1, 2))
        result, events = self.build(identities)
        self.assert_signing(result, events, APPLE)

    def test_explicit_identity_and_ad_hoc_override_skip_keychain(self):
        for override in (OTHER, "VoiceInk Custom Certificate", "-"):
            with self.subTest(override=override):
                result, events = self.build(identity(APPLE, "Apple Development: Developer"), override=override)
                self.assert_signing(result, events, override)
                self.assertFalse(any(event[0] == "security" for event in events))

    def test_unavailable_keychain_uses_ad_hoc(self):
        result, events = self.build(security_status=1)
        self.assert_signing(result, events, "-")

    def test_build_failure_does_not_copy_app(self):
        result, events = self.build(build_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(event[0] == "xcodebuild" for event in events))
        self.assertFalse(any(event[0] in ("ditto", "xattr") for event in events))


if __name__ == "__main__":
    unittest.main()
