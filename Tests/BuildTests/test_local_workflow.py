import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "com.prakashjoshipax.VoiceInk"
REAL_GIT = subprocess.check_output(["xcrun", "--find", "git"], text=True).strip()
REAL_MAKE = subprocess.check_output(["xcrun", "--find", "gnumake"], text=True).strip()
TOOL = r'''
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["EVENTS"], "a") as output:
    output.write(json.dumps([tool, args, os.environ.get("DEVELOPER_DIR"), os.environ.get("GIT_SSH_COMMAND")]) + "\n")
if tool == "xcode-select":
    print(os.environ["SELECTED_XCODE"])
elif tool == "xcodebuild":
    if args == ["-version"]:
        print("Xcode " + os.environ.get("XCODE_VERSION", "27.0") + "\nBuild version fixture")
    else:
        if os.environ.get("BUILD_FAIL"):
            sys.exit(1)
        app = Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release/VoiceInk.app"
        (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.prakashjoshipax.VoiceInk", "CFBundleExecutable": "VoiceInk"}))
        executable = app / "Contents/MacOS/VoiceInk"
        executable.write_text("new")
        executable.chmod(0o755)
elif tool == "xcrun":
    if "swift" in args:
        print("Apple Swift version " + os.environ.get("SWIFT_VERSION", "6.4"))
    elif "metal" in args and os.environ.get("NO_METAL"):
        sys.exit(1)
    else:
        print("/fixture/sdk")
elif tool == "security":
    print('1) ' + 'A' * 40 + ' "Apple Development: Fixture"')
elif tool == "codesign":
    app = Path(args[-1])
    if os.environ.get("SIGNATURE_FAIL") == app.name:
        sys.exit(1)
    if app == Path(os.environ.get("DESTINATION", "/none")) and "--verify" in args:
        if os.environ.get("SWAP_FAIL"):
            sys.exit(1)
        if os.environ.get("SWAP_SIGNAL"):
            os.kill(os.getppid(), int(os.environ["SWAP_SIGNAL"]))
    print("Identifier=" + os.environ.get("SIGNATURE_ID", "com.prakashjoshipax.VoiceInk"))
elif tool == "ditto":
    if os.environ.get("COPY_FAIL"):
        Path(args[1]).mkdir()
        (Path(args[1]) / "partial").write_text("partial")
        sys.exit(1)
    shutil.copytree(args[0], args[1])
    if os.environ.get("COPY_SIGNAL"):
        os.kill(os.getppid(), int(os.environ["COPY_SIGNAL"]))
elif tool == "osascript":
    state = Path(os.environ["PROCESS_STATE"])
    running = state.read_text() == "running"
    if args[-1] == "quit" and not os.environ.get("STUCK_PROCESS"):
        state.write_text("stopped")
    print("[42]" if running else "[]")
elif tool == "open":
    if os.environ.get("OPEN_FAIL"):
        sys.exit(1)
    Path(os.environ["PROCESS_STATE"]).write_text("running")
elif tool == "git":
    if "fetch" in args:
        if os.environ.get("FETCH_FAIL"):
            sys.exit(1)
        os.execv(os.environ["REAL_GIT"], ["git", "fetch", "--no-tags", os.environ["GIT_FIXTURE_REMOTE"], "refs/heads/main:refs/remotes/origin/main"])
    os.execv(os.environ["REAL_GIT"], ["git", *args])
'''


def bundle(path, content="new", identifier=BUNDLE_ID):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "VoiceInk",
    }))
    executable = path / "Contents/MacOS/VoiceInk"
    executable.write_text(content)
    executable.chmod(0o755)


class WorkflowFixtures(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".tmp/local-workflow-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(directory.cleanup)
        self.workspace = Path(directory.name)
        self.bin = self.workspace / "bin"
        self.bin.mkdir()
        (self.bin / "make").symlink_to(REAL_MAKE)
        (self.bin / "python3").symlink_to(sys.executable)
        for name in ("xcode-select", "xcodebuild", "xcrun", "security", "codesign", "ditto", "osascript", "open", "git"):
            tool = self.bin / name
            tool.write_text(f"#!{sys.executable}\n{TOOL}")
            tool.chmod(0o755)
        self.developer = self.workspace / "Xcode.app/Contents/Developer"
        (self.developer / "usr/bin").mkdir(parents=True)
        (self.developer / "usr/bin/xcodebuild").touch()
        self.events_path = self.workspace / "events"
        self.events_path.touch()
        self.process_state = self.workspace / "process"
        self.process_state.write_text("stopped")
        self.environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                                EVENTS=str(self.events_path), DEVELOPER_DIR=str(self.developer),
                                SELECTED_XCODE=str(self.developer), REAL_GIT=REAL_GIT,
                                PROCESS_STATE=str(self.process_state))
        self.environment.pop("GIT_CONFIG_COUNT", None)

    def execute(self, command, **environment):
        return subprocess.run(command, cwd=self.workspace, env=dict(self.environment, **environment),
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)

    def events(self, name):
        return [json.loads(line) for line in self.events_path.read_text().splitlines()
                if json.loads(line)[0] == name]


class ToolchainTests(WorkflowFixtures):
    def check(self, **environment):
        return self.execute([sys.executable, str(ROOT / "scripts/xcode-toolchain.py")], **environment)

    def test_explicit_and_selected_full_xcode(self):
        for explicit in (str(self.developer), str(self.developer.parents[1]), ""):
            with self.subTest(explicit=explicit):
                result = self.check(DEVELOPER_DIR=explicit)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(str(self.developer), result.stdout)

    def test_command_line_tools_are_rejected(self):
        result = self.check(DEVELOPER_DIR=str(self.workspace / "CommandLineTools"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Full Xcode", result.stderr)

    def test_unsupported_xcode_and_swift(self):
        for environment, diagnostic in (({"XCODE_VERSION": "26.3"}, "Xcode 26.4"), ({"SWIFT_VERSION": "6.2"}, "Swift 6.3")):
            with self.subTest(environment=environment):
                result = self.check(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)

    def test_missing_metal_does_not_install_component(self):
        result = self.check(NO_METAL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Metal is unavailable", result.stderr)
        self.assertFalse(any("-downloadComponent" in event[1] for event in self.events("xcodebuild")))

    def test_build_only_runs_actual_make_recipe_with_signing_override_and_ssh(self):
        framework = self.workspace / "framework"
        framework.mkdir()
        command = ["make", "--no-print-directory", "-f", str(ROOT / "Makefile"), "local-build",
                   f"FRAMEWORK_PATH={framework}", f"LOCAL_DERIVED_DATA={self.workspace / 'build with spaces'}",
                   "LOCAL_CODESIGN_IDENTITY=-"]

        result = self.execute(command)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = next(event for event in self.events("xcodebuild") if "build" in event[1])
        self.assertIn("CODE_SIGN_IDENTITY=-", build[1])
        self.assertEqual(build[2], str(self.developer))
        self.assertEqual(build[3], "ssh -o BatchMode=yes")
        self.assertFalse(self.events("security"))
        self.assertFalse(self.events("ditto"))
        self.assertFalse(self.events("osascript"))
        self.assertTrue(self.events("codesign"))

    def test_workflow_build_runs_recipe_without_installing(self):
        checkout = self.workspace / "build checkout"
        checkout.mkdir()
        shutil.copytree(ROOT / "scripts", checkout / "scripts")
        shutil.copy(ROOT / "Makefile", checkout)
        home = self.workspace / "home"
        (home / "VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework").mkdir(parents=True)

        result = self.execute([sys.executable, str(checkout / "scripts/local-workflow.py"), "build"], HOME=str(home))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((checkout / ".local-build/Build/Products/Release/VoiceInk.app").exists())
        self.assertFalse((home / "Downloads").exists())
        self.assertFalse(self.events("ditto"))
        self.assertFalse(self.events("open"))

    def test_build_failure_does_not_verify_or_install_stale_output(self):
        framework = self.workspace / "framework"
        framework.mkdir()
        result = self.execute(["make", "--no-print-directory", "-f", str(ROOT / "Makefile"), "local-build",
                               f"FRAMEWORK_PATH={framework}", "LOCAL_CODESIGN_IDENTITY=-"], BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.events("codesign"))
        self.assertFalse(self.events("ditto"))


class RepositoryUpdateTests(WorkflowFixtures):
    def real_git(self, *arguments, cwd=None):
        result = subprocess.run([REAL_GIT, *arguments], cwd=cwd or self.repository,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def setUp(self):
        super().setUp()
        self.repository = self.workspace / "checkout"
        self.repository.mkdir()
        self.real_git("init", "-b", "main")
        self.real_git("config", "user.name", "Fixture")
        self.real_git("config", "user.email", "fixture@example.com")
        self.real_git("config", "commit.gpgsign", "false")
        scripts = self.repository / "scripts"
        scripts.mkdir()
        shutil.copy(ROOT / "scripts/local-workflow.py", scripts)
        (self.repository / "file").write_text("base\n")
        self.real_git("add", ".")
        self.real_git("commit", "-m", "base")
        self.real_git("remote", "add", "origin", "git@github.com:LuisUrrutia/VoiceInk.git")
        self.real_git("remote", "add", "upstream", "git@github.com:Beingpax/VoiceInk.git")
        self.remote = self.workspace / "remote.git"
        self.real_git("clone", "--bare", str(self.repository), str(self.remote))
        self.environment["GIT_FIXTURE_REMOTE"] = str(self.remote)
        self.real_git("checkout", "-b", "build/topic")

    def update(self, **environment):
        return self.execute([sys.executable, str(self.repository / "scripts/local-workflow.py"), "update"], **environment)

    def test_success_fetches_only_fork_main(self):
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        fetch = next(event for event in self.events("git") if "fetch" in event[1])
        self.assertEqual(fetch[1], ["fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main"])
        self.assertEqual(fetch[3], "ssh -o BatchMode=yes")
        self.assertIn("No upstream integration or publication", result.stdout)

    def test_all_dirty_work_is_preserved_without_stashing(self):
        (self.repository / "file").write_text("staged\n")
        self.real_git("add", "file")
        (self.repository / "file").write_text("unstaged\n")
        (self.repository / "untracked").write_text("untracked\n")
        before = self.real_git("status", "--porcelain")
        index = self.real_git("show", ":file")

        result = self.update()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Dirty working tree", result.stderr)
        self.assertEqual(self.real_git("status", "--porcelain"), before)
        self.assertEqual(self.real_git("show", ":file"), index)
        self.assertEqual((self.repository / "untracked").read_text(), "untracked\n")
        self.assertFalse(any("fetch" in event[1] or "stash" in event[1] for event in self.events("git")))

    def test_detached_and_protected_branches_do_not_fetch(self):
        for branch in ("main", "master", "upstream", "sync/upstream-fixture", None):
            with self.subTest(branch=branch):
                if branch is None:
                    self.real_git("checkout", "--detach")
                else:
                    self.real_git("checkout", "-B", branch)
                result = self.update()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Protected branch" if branch else "Detached HEAD", result.stderr)
        self.assertFalse(any("fetch" in event[1] for event in self.events("git")))

    def test_network_failure_does_not_claim_update(self):
        before = self.real_git("rev-parse", "HEAD")
        result = self.update(FETCH_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.real_git("rev-parse", "HEAD"), before)
        self.assertNotIn("updated from", result.stdout)

    def test_non_ssh_remote_is_rejected(self):
        self.real_git("remote", "set-url", "origin", "https://github.com/LuisUrrutia/VoiceInk.git")
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use SSH", result.stderr)

    def test_topic_rebase_conflict_restores_original_head(self):
        (self.repository / "file").write_text("topic\n")
        self.real_git("add", "file")
        self.real_git("commit", "-m", "topic")
        original = self.real_git("rev-parse", "HEAD")
        self.real_git("checkout", "main")
        (self.repository / "file").write_text("main\n")
        self.real_git("add", "file")
        self.real_git("commit", "-m", "main")
        self.real_git("push", str(self.remote), "main")
        self.real_git("checkout", "build/topic")

        result = self.update()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("original branch restored", result.stderr)
        self.assertEqual(self.real_git("rev-parse", "HEAD"), original)
        self.assertEqual(self.real_git("status", "--porcelain"), "")

    def test_git_file_metadata_preserves_unrelated_operation(self):
        # A separate git directory exercises the same .git-file lookup as a worktree.
        metadata = self.workspace / "git metadata"
        self.real_git("init", "--separate-git-dir", str(metadata))
        (metadata / "MERGE_HEAD").write_text(self.real_git("rev-parse", "HEAD"))

        result = self.update()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Existing Git operation", result.stderr)
        self.assertTrue((metadata / "MERGE_HEAD").exists())
        self.assertFalse(any("--abort" in event[1] for event in self.events("git")))

    def test_git_file_metadata_allows_successful_update(self):
        metadata = self.workspace / "git metadata"
        self.real_git("init", "--separate-git-dir", str(metadata))

        result = self.update()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repository / ".git").is_file())

    def test_existing_rebase_is_never_aborted(self):
        metadata = Path(self.real_git("rev-parse", "--git-path", "rebase-merge"))
        metadata = self.repository / metadata
        metadata.mkdir()
        (metadata / "owned-by-user").write_text("keep")

        result = self.update()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((metadata / "owned-by-user").read_text(), "keep")
        self.assertFalse(any("--abort" in event[1] for event in self.events("git")))


class InstallTests(WorkflowFixtures):
    def setUp(self):
        super().setUp()
        self.source = self.workspace / "Built.app"
        self.destination = self.workspace / "Installed.app"
        bundle(self.source)
        bundle(self.destination, content="old")
        self.environment["DESTINATION"] = str(self.destination)

    def install(self, *arguments, **environment):
        return self.execute([sys.executable, str(ROOT / "scripts/install-local-app.py"),
                             "--app", str(self.source), "--destination", str(self.destination), *arguments], **environment)

    def content(self):
        return (self.destination / "Contents/MacOS/VoiceInk").read_text()

    def assert_clean(self):
        self.assertEqual(list(self.workspace.glob(".Installed.app.install-*")), [])

    def test_successful_stopped_swap_preserves_signature(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.content(), "new")
        self.assertFalse(self.events("open"))
        self.assertTrue(all("--sign" not in event[1] for event in self.events("codesign")))
        self.assert_clean()

    def test_initial_install_without_existing_app(self):
        shutil.rmtree(self.destination)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.content(), "new")
        self.assert_clean()

    def test_partial_copy_preserves_original_and_never_stops_app(self):
        result = self.install(COPY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.content(), "old")
        self.assertFalse(self.events("osascript"))
        self.assert_clean()

    def test_verification_failure_preserves_original(self):
        for environment in ({"SIGNATURE_FAIL": "staged.app"}, {"SIGNATURE_ID": "wrong"}):
            with self.subTest(environment=environment):
                result = self.install(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.content(), "old")
                self.assertFalse(self.events("osascript"))
                self.assert_clean()

    def test_wrong_bundle_and_missing_executable_are_rejected(self):
        executable = self.source / "Contents/MacOS/VoiceInk"
        executable.chmod(0o644)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.content(), "old")
        self.assertFalse(self.events("ditto"))
        executable.chmod(0o755)
        info = self.source / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.app", "CFBundleExecutable": "VoiceInk"}))
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected bundle identity", result.stderr)
        self.assertEqual(self.content(), "old")

    def test_post_swap_verification_failure_rolls_back(self):
        result = self.install(SWAP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.content(), "old")
        self.assertIn("Restored previous", result.stdout)
        self.assert_clean()

    def test_running_app_rollback_relaunch_and_no_relaunch(self):
        for arguments in ((), ("--no-relaunch",)):
            with self.subTest(arguments=arguments):
                self.process_state.write_text("running")
                self.events_path.write_text("")
                result = self.install(*arguments, SWAP_FAIL="1")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.content(), "old")
                self.assertEqual(self.process_state.read_text(), "stopped" if arguments else "running")
                self.assert_clean()

    def test_existing_installation_lock_is_preserved(self):
        lock = self.workspace / ".Installed.app.install-lock"
        lock.mkdir()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.content(), "old")
        self.assertTrue(lock.exists())
        self.assertFalse(self.events("ditto"))

    def test_real_appkit_query_does_not_match_an_unrelated_bundle(self):
        code = ("import runpy; from pathlib import Path; "
                f"m = runpy.run_path({str(ROOT / 'scripts/install-local-app.py')!r}); "
                f"assert m['processes'](Path({str(self.workspace / 'Absent.app')!r})) == []")

        result = self.execute([sys.executable, "-B", "-c", code], PATH=os.environ["PATH"])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.content(), "old")

    def test_signals_during_copy_and_after_swap_restore_original(self):
        for phase in ("COPY_SIGNAL", "SWAP_SIGNAL"):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(phase=phase, signum=signum):
                    result = self.install(**{phase: str(signum)})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.content(), "old")
                    self.assert_clean()

    def test_running_app_relaunch_and_no_relaunch(self):
        for arguments in ((), ("--no-relaunch",)):
            with self.subTest(arguments=arguments):
                self.process_state.write_text("running")
                self.events_path.write_text("")
                result = self.install(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.content(), "new")
                self.assertEqual(bool(self.events("open")), not bool(arguments))
                actions = [event[1][-1] for event in self.events("osascript")]
                self.assertIn("quit", actions)
                self.assertTrue(all(event[1][-2] == str(self.destination) for event in self.events("osascript")))
                self.assert_clean()

    def test_refused_shutdown_is_bounded_and_preserves_app(self):
        self.process_state.write_text("running")
        result = self.install("--stop-timeout", "0", STUCK_PROCESS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without force-killing", result.stderr)
        self.assertEqual(self.content(), "old")
        self.assertFalse(self.events("open"))
        self.assert_clean()

    def test_relaunch_failure_reports_installation_success_accurately(self):
        self.process_state.write_text("running")
        result = self.install(OPEN_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installation succeeded, but relaunch failed", result.stderr)
        self.assertEqual(self.content(), "new")
        self.assert_clean()

    def test_unwritable_parent_fails_before_stopping_app(self):
        self.workspace.chmod(0o555)
        self.addCleanup(self.workspace.chmod, 0o755)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not writable", result.stderr)
        self.assertEqual(self.content(), "old")
        self.assertFalse(self.events("osascript"))


if __name__ == "__main__":
    unittest.main()
