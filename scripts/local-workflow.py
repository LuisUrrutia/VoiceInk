#!/usr/bin/env python3
"""Explicit repository update and build phases; installation is a separate command."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


class GitError(RuntimeError):
    def __init__(self, arguments, result):
        super().__init__(f"git {' '.join(arguments)} failed: {result.stderr.strip() or result.stdout.strip()}")
        self.returncode = result.returncode


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd=ROOT, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise GitError(arguments, result)
    return result.stdout.strip()


def require_idle_repository():
    for state in ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"):
        metadata = Path(git("rev-parse", "--git-path", state))
        if not metadata.is_absolute():
            metadata = ROOT / metadata
        if metadata.exists():
            raise RuntimeError(f"Existing Git operation ({state}); it was left untouched")


def update():
    branch = git("branch", "--show-current")
    if not branch:
        raise RuntimeError("Detached HEAD: switch to a topic branch before updating")
    if branch in ("main", "master", "upstream") or branch.startswith("sync/"):
        raise RuntimeError("Protected branch: use a separate merge-based synchronization PR for upstream integration")
    require_idle_repository()
    if git("status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Dirty working tree: commit or preserve staged, unstaged and untracked work before updating; no stash was created")
    for remote, repository in (("origin", "LuisUrrutia/VoiceInk"), ("upstream", "Beingpax/VoiceInk")):
        allowed = (f"git@github.com:{repository}.git", f"ssh://git@github.com/{repository}.git")
        if git("remote", "get-url", remote) not in allowed or git("remote", "get-url", "--push", remote) not in allowed:
            raise RuntimeError(f"{remote} must use SSH for {repository}")
    original = git("rev-parse", "HEAD")
    print(f"Fetching origin/main for topic branch {branch}", flush=True)
    git("fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main")
    if git("branch", "--show-current") != branch or git("rev-parse", "HEAD") != original:
        raise RuntimeError("Checkout changed during fetch; update was stopped")
    require_idle_repository()
    try:
        git("-c", "rebase.autoStash=false", "rebase", "origin/main")
    except GitError as error:
        active = any((ROOT / git("rev-parse", "--git-path", state)).exists()
                     for state in ("rebase-merge", "rebase-apply"))
        if error.returncode == 1 and active and git("rev-parse", "ORIG_HEAD") == original:
            git("rebase", "--abort")
            raise RuntimeError(f"Topic rebase failed; original branch restored. {error}") from error
        raise RuntimeError(f"Topic rebase failed; inspect Git state before continuing. {error}") from error
    print(f"Topic branch {branch} updated from origin/main. No upstream integration or publication performed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("check", "update", "build"))
    arguments = parser.parse_args()
    os.environ["GIT_TERMINAL_PROMPT"] = "0"
    os.environ["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    os.environ["GIT_EDITOR"] = "true"
    os.environ["GIT_SEQUENCE_EDITOR"] = "true"
    if arguments.phase == "update":
        update()
        return 0
    command = [sys.executable, str(ROOT / "scripts/xcode-toolchain.py")]
    if arguments.phase == "build":
        command += ["--", "make", "--no-print-directory", "local-build"]
    return subprocess.run(command, cwd=ROOT, stdin=subprocess.DEVNULL, check=False).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
