#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
test "$(git branch --show-current)" = personal

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

case "$(git remote get-url upstream)" in
    git@github.com:Beingpax/VoiceInk.git|ssh://git@github.com/Beingpax/VoiceInk.git) ;;
    *) fail "upstream must use SSH for Beingpax/VoiceInk" ;;
esac

remote_main=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git ls-remote upstream refs/heads/main)
IFS=$'\t' read -r remote_main_oid _ <<< "$remote_main"
test "$remote_main_oid" = "$(git rev-parse upstream/main)" ||
    fail "upstream/main is stale; fetch upstream before continuing"

if merge_head=$(git rev-parse --verify -q MERGE_HEAD); then
    test "$merge_head" = "$remote_main_oid" ||
        fail "the pending merge is not the latest upstream/main"
else
    git merge-base --is-ancestor upstream/main HEAD ||
        fail "personal does not contain the latest upstream/main"
fi

while IFS=$'\t' read -r pr_url reason; do
    [[ -z "$pr_url" || "$pr_url" == \#* ]] && continue
    [[ "$pr_url" =~ ^https://github\.com/Beingpax/VoiceInk/pull/([0-9]+)$ && -n "$reason" ]] ||
        fail "invalid entry in scripts/personal-prs.tsv: $pr_url"
    number="${BASH_REMATCH[1]}"

    metadata=$(gh pr view "$pr_url" --repo Beingpax/VoiceInk \
        --json state,headRefOid,baseRefName \
        --jq '[.state, .baseRefName, (.headRefOid // "")] | @tsv')
    IFS=$'\t' read -r state base_branch current_head <<< "$metadata"
    test "$base_branch" = main ||
        fail "$pr_url targets $base_branch, not upstream/main"
    if [[ "$state" == MERGED ]]; then
        printf '%s: merged upstream; no separate application needed\n' "$pr_url"
        continue
    fi
    [[ "$state" == OPEN || "$state" == CLOSED ]] ||
        fail "unknown state for $pr_url: $state"
    [[ "$current_head" =~ ^[0-9a-f]{40}$ ]] ||
        fail "missing head commit for $pr_url"

    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
        git fetch --no-tags upstream "refs/pull/$number/head"
    test "$(git rev-parse FETCH_HEAD)" = "$current_head" ||
        fail "$pr_url changed during the check; retry"

    if ! git merge-base --is-ancestor "$current_head" HEAD; then
        test "${merge_head:-}" = "$current_head" ||
            fail "$pr_url is not fully integrated; review and apply its current head"
    fi
    printf '%s: %s head %s is integrated\n' "$pr_url" "$state" "$current_head"
done < scripts/personal-prs.tsv

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
    -only-testing:VoiceInkTests \
    test
