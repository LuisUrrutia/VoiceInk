#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
test "$(git branch --show-current)" = personal
git merge-base --is-ancestor fix/secure-input-shortcuts HEAD
if merge_head=$(git rev-parse --verify -q MERGE_HEAD); then
    test "$merge_head" = "$(git rev-parse upstream/main)"
else
    git merge-base --is-ancestor upstream/main HEAD
fi

GIT_TERMINAL_PROMPT=0 \
GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf' \
GIT_CONFIG_VALUE_0='https://github.com/' \
xcodebuild -quiet \
    -project VoiceInk.xcodeproj \
    -scheme VoiceInk \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath .local-build \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGN_IDENTITY= \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:VoiceInkTests/SystemHotKeyTests \
    test
