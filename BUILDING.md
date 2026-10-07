# Building VoiceInk

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

`make local` prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds Release in `.local-build`, and copies `VoiceInk.app` to `~/Downloads`.

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

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `~/Downloads/VoiceInk.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands
- `make test-local-signing` — test local signing selection with Python 3, without using your Keychain or copying an app

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If signing identities are ambiguous, set `LOCAL_CODESIGN_IDENTITY` to the certificate fingerprint shown by `security find-identity -v -p codesigning`.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).
