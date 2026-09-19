# Personal branch policy

This file applies to the `personal` branch. The branch follows `Beingpax/VoiceInk`'s `main` and keeps only the pull requests or other changes explicitly requested for this fork. `scripts/personal-prs.tsv` is the list of tracked upstream PRs; GitHub, not that file, is the source of truth for each PR's current state.

## Before changing `personal`

For read-only requests, report any drift without changing the checkout. Before implementation or maintenance work:

1. Check that the checkout is on `personal` and preserve any uncommitted work. Confirm that `upstream` points to `git@github.com:Beingpax/VoiceInk.git`.
2. Fetch the latest upstream `main` over SSH: `git fetch --no-tags upstream refs/heads/main:refs/remotes/upstream/main`.
3. Merge `upstream/main` into `personal` before making other changes. Resolve conflicts so the result retains upstream behavior and every still-unmerged tracked PR. Do not rebase or rewrite `personal` merely to sync it.
4. For every entry in `scripts/personal-prs.tsv`, query its live GitHub state. If it is merged, upstream supplies it; do not apply it again. If it is open or closed without a merge, fetch its current `refs/pull/<number>/head` from `upstream` over SSH. If that head is not an ancestor of `personal`, review the PR diff and merge its missing changes after the upstream update. Resolve conflicts against the current upstream code and test the retained behavior. A changed PR head needs a new review even when an older head was applied.
5. Run `./scripts/check-personal-sync.sh`, the project build, and a smoke path outside the changed feature. The check must see the current remote `main`, every unmerged PR head in the branch history, and passing shortcut tests before the task is complete.

## Track requested PRs

Add one row to `scripts/personal-prs.tsv` when a PR is requested, including PRs already merged. Keep rows after a merge as history; the live state check then skips reapplication. Use the full upstream PR URL and a short reason for retaining it. Add a focused regression check for each new overlay, extending `scripts/check-personal-sync.sh` if its test is outside `VoiceInkTests`. For changes that are not PRs, record the request and its regression check in a separate, named section here; they must survive future upstream merges too.

The check is a snapshot, not a background updater. Repeat this sequence whenever work resumes on `personal`, and report any upstream or PR changes that cannot be integrated safely.

## Tracked local overlays

### Dictionary section descriptions

- Source: `feat/dictionary-section-descriptions` at `7f2633335deb9eb25043cc43b7179ddd108ca154`.
- Preserve named vocabulary sections, their optional descriptions, drag-and-drop membership, section-scoped duplicate terms, grouped enhancement prompts, editor UI, and section data in dictionary import/export and backups. Keep version 1 dictionary archives, unsectioned vocabulary, legacy-store migration, and isolated development persistence compatible.
- Regression: `./scripts/check-personal-sync.sh` runs `VocabularySectionTests` and `DictionarySmokeTests` as part of `VoiceInkTests`.
