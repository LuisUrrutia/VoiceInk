#!/usr/bin/env python3
"""Replace an explicitly selected app using verified staging and rollback."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


BUNDLE_ID = "com.prakashjoshipax.VoiceInk"
PROCESS_SCRIPT = r'''
ObjC.import('AppKit');
function run(args) {
    const destination = args[0];
    const quit = args[1] === 'quit';
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    const pids = [];
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        const url = app.bundleURL;
        if (!ObjC.unwrap(url)) continue;
        if (ObjC.unwrap(url.URLByResolvingSymlinksInPath.path) === destination) {
            pids.push(Number(app.processIdentifier));
            if (quit && !app.terminate) throw new Error('Application refused graceful termination');
        }
    }
    return JSON.stringify(pids);
}
'''


def run(command, timeout=None):
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, check=False, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, command))} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout, result.stderr


def inspect_bundle(app):
    if not app.is_dir() or app.is_symlink():
        raise RuntimeError(f"Application must be a real bundle directory: {app}")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "VoiceInk":
        raise RuntimeError(f"Unexpected bundle identity or executable: {app}")
    executable = app / "Contents/MacOS/VoiceInk"
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError(f"Missing executable VoiceInk: {app}")


def verify_bundle(app):
    inspect_bundle(app)
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    output = "\n".join(run(["codesign", "-d", "--verbose=4", str(app)]))
    if not re.search(r"^Identifier=" + re.escape(BUNDLE_ID) + r"$", output, re.MULTILINE):
        raise RuntimeError(f"Signature identifier does not match {BUNDLE_ID}: {app}")


def processes(destination, action="status"):
    stdout, _ = run(["osascript", "-l", "JavaScript", "-e", PROCESS_SCRIPT, str(destination), action], timeout=5)
    pids = json.loads(stdout)
    if not isinstance(pids, list) or any(type(pid) is not int or pid <= 0 for pid in pids):
        raise RuntimeError("Invalid application process response")
    return pids


def stop(destination, timeout):
    pids = processes(destination)
    if not pids:
        return False
    print(f"Requesting graceful shutdown of {destination} (PIDs {pids})", flush=True)
    processes(destination, "quit")
    deadline = time.monotonic() + timeout
    while processes(destination):
        if time.monotonic() >= deadline:
            raise RuntimeError("Application is still running; installation canceled without force-killing it")
        time.sleep(0.2)
    return True


def launch(destination):
    run(["open", "-n", str(destination)], timeout=5)
    deadline = time.monotonic() + 10
    while True:
        pids = processes(destination)
        if pids:
            print(f"Relaunch observed at {destination} (PIDs {pids})", flush=True)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Launch was requested but no running application was observed at {destination}")
        time.sleep(0.2)


@contextmanager
def atomic_state_change():
    # Deliver cancellation after rename and its ownership flag have both changed.
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def install(source, destination, timeout, no_relaunch):
    if destination.is_symlink():
        raise RuntimeError("Destination must not be a symbolic link")
    source = source.resolve()
    destination = destination.parent.resolve() / destination.name
    if source == destination or source in destination.parents or destination in source.parents:
        raise RuntimeError("Source and destination must be separate bundles")
    if destination.suffix != ".app" or not destination.parent.is_dir():
        raise RuntimeError("Destination must be an .app path in an existing directory")
    if not os.access(destination.parent, os.W_OK | os.X_OK):
        raise RuntimeError(f"Destination directory is not writable: {destination.parent}")
    verify_bundle(source)
    if destination.exists():
        inspect_bundle(destination)

    lock = destination.parent / f".{destination.name}.install-lock"
    lock.mkdir()
    workspace = None
    backed_up = swapped = committed = was_running = False
    try:
        workspace = Path(tempfile.mkdtemp(prefix=f".{destination.name}.install-", dir=destination.parent))
        staged = workspace / "staged.app"
        backup = workspace / "backup.app"
        run(["ditto", str(source), str(staged)])
        verify_bundle(staged)
        was_running = bool(processes(destination))
        if was_running:
            stop(destination, timeout)
        if processes(destination):
            raise RuntimeError("Application restarted during shutdown; installation canceled")
        with atomic_state_change():
            if destination.exists():
                destination.rename(backup)
                backed_up = True
            staged.rename(destination)
            swapped = True
        verify_bundle(destination)
        with atomic_state_change():
            committed = True
        print(f"Installed verified application at {destination}", flush=True)
    except BaseException:
        with atomic_state_change():
            if not committed:
                if swapped:
                    destination.rename(workspace / "failed.app")
                if backed_up:
                    backup.rename(destination)
                    backed_up = False
                    print(f"Restored previous application at {destination}", flush=True)
        if was_running and not no_relaunch and not committed:
            try:
                if not processes(destination):
                    launch(destination)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                print(f"Rollback restored files, but relaunch failed: {error}", file=sys.stderr)
        raise
    finally:
        if workspace is not None:
            if backed_up and not committed:
                print(f"Recovery backup retained at {workspace}; restore it manually. Lock retained at {lock}", file=sys.stderr)
            else:
                try:
                    shutil.rmtree(workspace)
                finally:
                    lock.rmdir()
        else:
            lock.rmdir()
    if was_running and not no_relaunch:
        try:
            launch(destination)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            raise RuntimeError(f"Application installation succeeded, but relaunch failed: {error}") from error
    else:
        print("Application was left stopped (--no-relaunch or previously stopped).")


def interrupted(signum, _frame):
    raise RuntimeError(f"Installation interrupted by signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--stop-timeout", type=float, default=10)
    parser.add_argument("--no-relaunch", action="store_true")
    arguments = parser.parse_args()
    if arguments.verify_only:
        if arguments.destination:
            parser.error("--verify-only cannot be combined with --destination")
        verify_bundle(arguments.app)
        print(f"Verified bundle identity, executable and signature at {arguments.app}")
        return 0
    if not arguments.destination:
        parser.error("Installation requires an explicit --destination")
    if not 0 <= arguments.stop_timeout <= 60:
        parser.error("--stop-timeout must be between 0 and 60 seconds")
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    install(arguments.app, arguments.destination, arguments.stop_timeout, arguments.no_relaunch)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
