# Building VoiceInk

## Requirements

- macOS 15.0 or later
- Full Xcode 26.4 or later, Swift 6.3 or later, the macOS SDK and Metal Toolchain
- Git and Python 3

The pinned `mlx-swift` 0.31.6 manifest requires Swift 6.3:
https://github.com/ml-explore/mlx-swift/blob/0bb916c67f4b9e5c682cbe02a42c701c93ab5021/Package.swift.
The app's macOS 15 deployment target is distinct from the macOS version required to run Xcode. Check Apple's requirements at https://developer.apple.com/xcode/system-requirements.

`make check` checks the actual Xcode, Swift, SDK and Metal tools. Build commands honor an explicit `DEVELOPER_DIR`; otherwise they try the current `xcode-select` directory followed by installed `/Applications/Xcode*.app` bundles until a compatible full toolchain is found. An invalid explicit override fails instead of silently choosing another Xcode. No command changes the global `xcode-select` setting.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check
```

If Metal is missing, use **Xcode Settings > Components > Metal Toolchain**. An explicit CLI alternative is:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

The check only diagnoses missing components; it does not install them. Apple's component instructions are at https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components.

## Local Build

```bash
git clone git@github.com:LuisUrrutia/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

`make local` prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds Release incrementally in `.local-build`, verifies the bundle and replaces `~/Downloads/VoiceInk.app` through the staged installation described below. It can gracefully stop that exact Downloads app and leaves it stopped. Use `make local-build` to build without copying, installing or stopping any app. Each checkout keeps its own `.local-build`; neither target deletes the shared dependency directory. GitHub dependency transport uses noninteractive SSH.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity. If none or multiple are found, it tries a valid code-signing identity named exactly `VoiceInk Local Dev`. It selects the certificate by its SHA-1 fingerprint, treating duplicate listings of the same certificate as one identity. If neither type has a unique identity, it falls back to ad-hoc signing.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may require macOS permissions again after rebuilding.

### Explicit update, build and installation phases

Run these phases from the checkout you intend to use. The default build path has no repository update or application replacement:

```bash
python3 scripts/local-workflow.py check
python3 scripts/local-workflow.py build
```

`build` runs the actual `make local-build` recipe, including deterministic signing and bundle verification. Its output is `.local-build/Build/Products/Release/VoiceInk.app`. `LOCAL_CODESIGN_IDENTITY=-` and certificate overrides also apply to this command.

To update an ordinary topic branch from the maintained fork's current `origin/main`, run the separate update phase, then build:

```bash
python3 scripts/local-workflow.py update
python3 scripts/local-workflow.py build
```

`update` requires a clean tree, including the index and untracked files, and verified SSH remotes for `LuisUrrutia/VoiceInk` and `Beingpax/VoiceInk`. It refuses detached HEAD, `main`, `master`, the fork's `upstream` mirror, synchronization branches and existing Git operations. It fetches only `origin/main` and rebases the topic's commits. A fetch error fails the phase; a conflicting rebase started by this command is aborted to restore the original topic branch. Existing operations and user stashes remain untouched, including in worktrees whose `.git` is a file. Commit or preserve local work yourself before updating.

This command does not push or synchronize upstream. Upstream integration belongs in a separate merge-based synchronization PR under `AGENTS.md`; publish topic changes through a fork PR targeting `main`. No background updater or schedule is configured.

Application replacement is an independent, explicit operation. For example, after reviewing your local build:

```bash
python3 scripts/install-local-app.py \
  --app .local-build/Build/Products/Release/VoiceInk.app \
  --destination /Applications/VoiceInk.app
```

The destination's parent must already exist and be writable; the command does not use `sudo`. It checks the bundle identifier `com.prakashjoshipax.VoiceInk`, executable `VoiceInk` and code signature, copies with `ditto` into a private directory beside the destination, and verifies that staged copy before touching the old app. It requests graceful termination only for running applications whose bundle path matches the destination, waits up to 10 seconds, and fails without force-killing if the app remains running. Use `--stop-timeout` to select a bounded wait of 0–60 seconds.

The old bundle is renamed into a backup on the same volume. Copy, verification, signal or swap errors before the verified installation commits restore it. A destination lock prevents concurrent installations by this command. If rollback itself fails, the error reports the retained recovery directory; restore `backup.app` manually before removing the lock. A hard kill or machine crash can leave the lock and recovery directory for inspection. The command never removes extended attributes or changes the completed bundle's signature.

An app that was running is relaunched after a successful swap; success is reported only after its exact bundle path appears in the running-app list. A relaunch failure returns an error and keeps the verified new installation. `--no-relaunch` leaves the app stopped, including after rollback. A previously stopped app remains stopped. Installation authorizes stopping the selected app, so finish dictation before running it.

Verify an existing bundle without installation:

```bash
python3 scripts/install-local-app.py --app .local-build/Build/Products/Release/VoiceInk.app --verify-only
```

`make test-local-workflow` executes the actual commands with isolated Git repositories, fake bundles and external-tool fixtures. It covers toolchain errors, work preservation, topic conflicts, Git metadata, staging, rollback, signals, shutdown and relaunch. These tests do not establish real macOS permission retention, dictation continuity or hardware behavior.

### Local signing certificate

If you do not have an Apple Development identity, create a certificate once in Keychain Access:

1. Choose **Keychain Access > Certificate Assistant > Create a Certificate**.
2. Set the name to `VoiceInk Local Dev`, the identity type to **Self Signed Root**, and the certificate type to **Code Signing**.
3. Finish the assistant and keep the certificate and its private key in your login keychain.
4. If it is not listed as a valid identity, open the certificate's **Trust** settings and set **Code Signing** to **Always Trust**.
5. Confirm it appears in `security find-identity -v -p codesigning`, then run `make local`.

Keep using the same certificate and app bundle identifier across rebuilds. A certificate-backed signature gives macOS a stable designated requirement; the executable's CDHash can still change. Approve Accessibility and other required permissions after the first build or a signing identity change. Ad-hoc builds can use granted permissions, but rebuilding can require approval again. Recheck auto-paste after rebuilding to confirm permission retention on your macOS version.

This certificate is for local development. Certificate creation and trust settings are manual; `make local` only reads available identities. Apple's certificate setup and designated-requirement details are documented at https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html and https://developer.apple.com/library/archive/technotes/tn2206/_index.html.

## Other Commands

- `make check` — verify compatible full Xcode, Swift, macOS SDK and Metal
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `~/Downloads/VoiceInk.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands
- `make test-local-signing` — test local signing selection with Python 3, without using your Keychain or copying an app
- `make test-local-workflow` — test prerequisites, topic updates and installation in isolated fixtures
- `make local-build` — build and verify a local Release app without copying or installing

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. Local packaging applies `LOCAL_BUILD` through `make local` or `make local-build`.

Debug keeps the separate `VoiceInk Dev.app` identity and development persistence. Release packaging uses the same toolchain selector, with the existing `VOICEINK_XCODE_DEVELOPER_DIR` override taking precedence over `DEVELOPER_DIR`. Existing-app packaging does not require a compiler check; archiving and archive export do.

## Regenerate Icons

Phosphor 2.1.1 outlined custom symbols use the regular weight and are checked into `VoiceInk/Assets.xcassets/Phosphor`. Normal builds use these assets without downloading icons or running a converter.

To change the catalog, edit `SYMBOLS` in `scripts/phosphor-symbols.py`, then regenerate it with Python 3 and SwiftDraw 0.29.0:

```bash
git clone --depth 1 --branch 0.29.0 git@github.com:swhitty/SwiftDraw.git .tmp/swiftdraw
swift build --package-path .tmp/swiftdraw -c release --product swiftdrawcli
python3 scripts/phosphor-symbols.py .tmp/swiftdraw/.build/release/swiftdrawcli
```

The generator verifies the pinned Phosphor archive's checksum and stages all conversions before replacing the catalog, Swift mapping and bundled MIT license. Download or conversion failures preserve the existing files. Include all three outputs in the same commit.

Use `Image(appSymbol:)` or `Label(_:appSymbol:)` with a mapped SF Symbol name. These identifiers preserve saved mode icons, including names ending in `.fill`; all artwork comes from Phosphor's regular outlines. Unknown imported names use a Phosphor question mark. Add an alias to the catalog before introducing a new interface symbol. Selected sidebar outlines use VoiceInk's current accent color. The custom symbols keep one fixed stroke weight while their size follows the font.

VoiceInk app and menu-bar branding, bundled provider logo assets, installed application icons and user-selected emojis retain their original artwork. App Shortcuts use system symbols because Apple's `AppShortcut` API requires `systemImageName`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If signing identities are ambiguous, set `LOCAL_CODESIGN_IDENTITY` to the certificate fingerprint shown by `security find-identity -v -p codesigning`.
- For additional help with this fork, open an issue at https://github.com/LuisUrrutia/VoiceInk/issues.
