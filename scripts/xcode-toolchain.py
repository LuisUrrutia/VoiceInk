#!/usr/bin/env python3
"""Select and check the full Xcode toolchain used by VoiceInk's pinned packages."""

import glob
import os
from pathlib import Path
import re
import subprocess
import sys


MIN_XCODE = (26, 4)
MIN_SWIFT = (6, 3)


def capture(command, environment):
    result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{' '.join(command)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def version(output, pattern, minimum, name):
    match = re.search(pattern, output)
    if not match or tuple(map(int, match.groups())) < minimum:
        raise RuntimeError(f"{name} {'.'.join(map(str, minimum))} or later is required; found {output.strip()}")
    return tuple(map(int, match.groups()))


def inspect(directory, environment):
    directory = Path(directory).resolve()
    if not (directory / "usr/bin/xcodebuild").is_file():
        raise RuntimeError(f"Full Xcode is required at {directory}; Command Line Tools alone are insufficient")
    selected = dict(environment, DEVELOPER_DIR=str(directory))
    xcode = capture(["xcodebuild", "-version"], selected)
    xcode_version = version(xcode, r"Xcode (\d+)\.(\d+)", MIN_XCODE, "Xcode")
    swift = capture(["xcrun", "swift", "--version"], selected)
    version(swift, r"Swift version (\d+)\.(\d+)", MIN_SWIFT, "Swift")
    capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"], selected)
    try:
        capture(["xcrun", "--sdk", "macosx", "metal", "--version"], selected)
    except RuntimeError as error:
        raise RuntimeError(
            f"Metal is unavailable in {directory}. Install the Metal Toolchain through Xcode Settings > Components, "
            "or explicitly run xcodebuild -downloadComponent MetalToolchain with this DEVELOPER_DIR. "
            f"No component was installed automatically. {error}"
        ) from error
    return selected, xcode_version, xcode.strip(), swift.splitlines()[0]


def select(environment):
    explicit = environment.get("DEVELOPER_DIR")
    if explicit:
        if explicit.endswith(".app"):
            explicit = str(Path(explicit) / "Contents/Developer")
        return inspect(explicit, environment)

    candidates = []
    try:
        candidates.append(capture(["xcode-select", "-p"], environment).strip())
    except RuntimeError:
        pass
    candidates.extend(sorted(glob.glob("/Applications/Xcode*.app/Contents/Developer")))
    failures = []
    for directory in dict.fromkeys(candidates):
        try:
            return inspect(directory, environment)
        except RuntimeError as error:
            failures.append(str(error))
    raise RuntimeError("No compatible full Xcode found. Set DEVELOPER_DIR explicitly. " + "\n".join(failures))


def main():
    arguments = sys.argv[1:]
    if arguments in (["--help"], ["-h"]):
        print("Usage: scripts/xcode-toolchain.py [-- command arguments...]\n"
              "Checks full Xcode >= 26.4, Swift >= 6.3, macOS SDK and Metal.\n"
              "Honors DEVELOPER_DIR; otherwise tries xcode-select and installed Xcode apps.\n"
              "Does not change xcode-select or download components.")
        return 0
    if arguments and (arguments[0] != "--" or len(arguments) == 1):
        raise RuntimeError("Expected -- followed by a command, or no arguments to check prerequisites")
    environment, _, xcode, swift = select(os.environ)
    print(f"Developer directory: {environment['DEVELOPER_DIR']}\n{xcode}\n{swift}\nmacOS SDK and Metal: available", flush=True)
    if arguments:
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        count = int(environment.get("GIT_CONFIG_COUNT", "0"))
        environment[f"GIT_CONFIG_KEY_{count}"] = "url.git@github.com:.insteadOf"
        environment[f"GIT_CONFIG_VALUE_{count}"] = "https://github.com/"
        environment["GIT_CONFIG_COUNT"] = str(count + 1)
        os.execvpe(arguments[1], arguments[1:], environment)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
