# Personal fork maintenance

These instructions apply to `personal` and the topic and synchronization branches that target it. `AGENTS.md` is the canonical project policy; `CLAUDE.md` imports it.

`personal` is the maintained version of this fork. It follows `Beingpax/VoiceInk`'s `main` while retaining changes explicitly requested for this fork. Upstream review or acceptance is not a prerequisite for keeping those changes here.

## Repository and project context

- `origin`: `git@github.com:LuisUrrutia/VoiceInk.git` (the personal fork).
- `upstream`: `git@github.com:Beingpax/VoiceInk.git` (the original repository).
- Use SSH for Git network operations. Verify both remotes before fetching or publishing; do not infer the PR destination from the name `origin` or GitHub's default branch.
- VoiceInk is a native macOS dictation app written in Swift and SwiftUI. The Xcode project is `VoiceInk.xcodeproj`, the scheme is `VoiceInk`, and the deployment target is macOS 15.0.
- Feature code lives in `VoiceInk/Features/`; persistence lives in `VoiceInk/Infrastructure/Persistence/`. Regression tests live in `Tests/VoiceInkTests/`. Inspect `Makefile` and `BUILDING.md` for build and packaging commands, and the Xcode project for current build settings.

## Changes to the fork

For read-only requests, report drift without changing the checkout. Before editing, inspect the current branch, working tree, and requested scope; preserve uncommitted work.

1. Fetch `origin/personal` over SSH and use its current tip as the base for a focused topic branch, such as `feat/<change>`, `fix/<change>`, or `docs/<change>`. Keep unrelated work out of the branch. Use the existing worktree policy for branch and worktree lifecycle operations.
2. Implement the requested change and its applicable checks. Record new retained behavior and its regression check as described below.
3. Publish the topic branch to `origin` and open a PR in `LuisUrrutia/VoiceInk` with base `personal`. Review the diff against that base and describe the behavior and actual validation. The inherited upstream notices that PRs are not accepted apply to `Beingpax/VoiceInk`; they do not prohibit PRs within this fork. Submit a PR to upstream only when explicitly requested.
4. Update ordinary topic PRs from `personal` by rebasing their own commits, following the existing publication rules. Merge approved changes through the fork PR; do not commit directly to `personal` or force-push it. Opening a PR does not authorize merging it or replacing an installed app.

Upstream synchronization is a separate maintenance task, performed when requested or before a fork release. Do not automatically merge upstream into every feature branch when work resumes. If upstream drift affects the requested change, report it and keep synchronization reviewable as a separate PR.

## Synchronize with upstream

1. Verify the remotes and preserve local work. Refresh the fork base with `git fetch --no-tags origin refs/heads/personal:refs/remotes/origin/personal` and upstream with `git fetch --no-tags upstream refs/heads/main:refs/remotes/upstream/main`. Create a dedicated `sync/upstream-<date>` branch from the current `origin/personal`.
2. Merge `upstream/main` into the synchronization branch. Preserve the original upstream commits and the fork's retained behavior. Resolve conflicts using the current implementation and regression contracts below, rather than choosing an entire side of a conflict.
3. For every entry in `scripts/personal-prs.tsv`, query its live GitHub state, current head, and merge commit when merged. GitHub is the authority; the file records retention intent. If a PR is merged and its merge commit is included in the fetched upstream history, upstream supplies it: do not apply it again. If its merge commit is not yet included, refresh upstream before proceeding. For an open or closed unmerged PR, fetch its current `refs/pull/<number>/head` from `upstream` over SSH. Review a changed head even when an older version was applied. If the current head is not an ancestor of the synchronization branch, review the diff and merge its missing changes. Preserve ancestry so the synchronization checker can verify the retained head.
4. Check upstream and retained-head ancestry on the synchronization branch, run the tests and build below, and exercise a smoke path outside the affected features. Report any head changes or conflicts that cannot be integrated safely.
5. Open a synchronization PR in `LuisUrrutia/VoiceInk` with base `personal`. Integrate it with a merge commit so the upstream and retained PR heads remain ancestors of `personal`; do not squash or rebase-merge this PR. Do not rebase or rewrite `personal` to synchronize it. If the base advances, rebuild the synchronization branch from the latest `origin/personal` and repeat the integration and checks, rather than rebasing the original upstream commits.
6. After an authorized PR merge, update the `personal` checkout without discarding local work and run `./scripts/check-personal-sync.sh`. This script requires the current branch to be exactly `personal`; it checks the live remote main, unmerged retained PR heads, and the full `VoiceInkTests` suite. Do not claim final synchronization verification until it passes on the integrated branch. If upstream or a retained head moved in the meantime, prepare another integration and repeat the checks.

The check is a snapshot, not a background updater. Recheck live upstream and retained PR state on each synchronization task. Installation, signing, and releases are separate requested operations.

## Retain requested changes

`scripts/personal-prs.tsv` tracks only PRs from `Beingpax/VoiceInk`, including requested PRs already merged. Add a row with the full upstream PR URL and a short retention reason. Keep rows after a merge as history; the live check skips reapplication of merged PRs.

For changes made through this fork's PRs or without an upstream PR, add a named section under **Tracked local overlays** with the request or source, required behavior, and regression check. Do not put fork PR URLs in the upstream-only TSV. Add a focused regression check for each new overlay; extend `scripts/check-personal-sync.sh` if its test is outside `VoiceInkTests`.

Preserve the required behavior when upstream implements the same capability differently. Remove redundant fork code only after confirming that upstream satisfies the retained contract and its regression checks pass. A closed, unmerged upstream PR remains retained until the user explicitly requests its removal.

## Validation and local builds

For functional changes, run a focused behavioral test, the build, and a smoke path outside the changed feature. Synchronization also requires the full `VoiceInkTests` suite and ancestry checks. Documentation-only changes require scope, command, reference, and import checks; do not report app tests as rerun when only the instructions changed.

Run the test suite from the checkout root with GitHub package transport rewritten to SSH:

```sh
env GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf' \
  GIT_CONFIG_VALUE_0='https://github.com/' \
  xcodebuild -quiet -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .local-build \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:VoiceInkTests test
```

For a focused test, narrow `-only-testing` to the relevant test class or suite. For the build, use the same invocation with `build` in place of `-only-testing:VoiceInkTests test`. Report the exact commands and outcomes. Build prerequisites include Xcode and the whisper framework configured by `Makefile`; apply the same SSH transport environment when invoking make targets that fetch dependencies.

Use the Debug `VoiceInk Dev.app` for development smoke checks. Its bundle identity and persistence are separate from the installed app; `LOCAL_BUILD` also has its own persistence directory. Preserve these boundaries when changing storage or migration code.

When local packaging is requested, inspect `make local` first: it recreates `.local-build` and replaces `~/Downloads/VoiceInk.app`. It does not install into `/Applications`. `make clean` removes the shared `~/VoiceInk-Dependencies` directory, so it is not a routine checkout cleanup command. Verify the actual bundle signature when signing is requested; a build setting alone is not evidence of the final signer.

## Tracked local overlays

### Dictionary section descriptions

- Source: `feat/dictionary-section-descriptions` at `7f2633335deb9eb25043cc43b7179ddd108ca154`.
- Preserve named vocabulary sections, their optional descriptions, drag-and-drop membership, section-scoped duplicate terms, grouped enhancement prompts, editor UI, and section data in dictionary import/export and backups. Keep version 1 dictionary archives, unsectioned vocabulary, legacy-store migration, and isolated development persistence compatible.
- Regression: `./scripts/check-personal-sync.sh` runs `VocabularySectionTests` and `DictionarySmokeTests` as part of `VoiceInkTests`.

### Dictionary section order

- Request: Show Vocabulary before Word Replacements in Dictionary.
- Preserve Vocabulary as the first option in the Dictionary section selector, followed by Word Replacements.
- Regression: `DictionarySmokeTests.testVocabularyPrecedesWordReplacementsInSectionSelector`, included in `VoiceInkTests` by `./scripts/check-personal-sync.sh`.

### Model catalog categories, filters, and sorting

- Request: Separate speech models from enhancement models and services, and filter and sort the catalog.
- Preserve Speech Models and Enhancement Models as the primary categories, with Local, Cloud, and Custom as secondary sources. Keep VoiceInk Refine, Ollama, and CLI services under Enhancement Models, and show only the selected capability in cloud and custom model lists and cloud provider panels.
- Local model lists support All Models, Installed, and Not Installed. Count supported built-in Apple Speech and imported local models as installed; reflect completed downloads and deletions. Ollama and CLI services remain separately configurable and are outside the installation filter.
- Local speech models support catalog order, fastest first, highest accuracy first, and name order. Use existing catalog ratings across local backends, keep unrated models last when sorting by ratings, and preserve catalog order for equal ratings.
- Regression: `ModelCatalogTests`, included in `VoiceInkTests` by `./scripts/check-personal-sync.sh`, covers local filtering, installation snapshots, sorting, and cloud provider capability selection. Verify category routing, download/deletion refresh, service configuration access, and empty-state recovery in `VoiceInk Dev.app` when changing the catalog UI.

### Native interface and optional model setup

- Request: Redesign VoiceInk around a compact macOS interface inspired by Superwhisper, remove VoiceInk Pro, and make onboarding model selection optional.
- Preserve grouped navigation with all eight feature destinations, a resizable window with a collapsible sidebar, light and dark appearance, and access to model categories, installation filters, sorting, search, and download controls. Preserve compact model-library rows with accessible detail controls and compact, grouped settings. Keep existing notification route names compatible.
- Use native Liquid Glass for navigation and controls on macOS 26 or later, with native fallbacks for macOS 15. Keep content surfaces uniform, with no decorative gradient overlays in History or the mode editor and no added sidebar divider. The final onboarding step offers Open VoiceInk without a redundant Skip action.
- Keep VoiceInk Pro branding, upsells, and app license, trial, purchase, or account gates absent. Do not append VoiceInk promotional text to delivered transcriptions. Preserve legal license notices and third-party provider authentication.
- Allow users with the required permissions and a selected microphone to skip model setup, finish onboarding without a model or provider, and configure dictation later from Home or Models. Preserve the skip decision across restarts, keep required permission checks, and resume legacy license-stage sessions at the account-free final step.
- Regression: `OnboardingFlowTests`, `NavigationTests`, and `ModelCatalogTests` run in `VoiceInkTests` through `./scripts/check-personal-sync.sh`. Verify native navigation, model detail controls, onboarding skip, resizing, and both appearance modes in `VoiceInk Dev.app` when changing these surfaces. Check glass controls, flat History and mode-editor surfaces, and the final onboarding action. Check that onboarding and settings contain no Pro or purchase prompts and completed transcriptions contain no appended VoiceInk promotion.
