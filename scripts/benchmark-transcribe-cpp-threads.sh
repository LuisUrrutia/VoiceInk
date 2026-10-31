#!/usr/bin/env bash
# Opt-in transcribe.cpp thread-count/QoS benchmark (TranscribeCppThreadingBenchmarkTests).
# Downloads into a scratch directory outside app persistence; the installed Cohere model is
# read in place when its checksum is valid. Extra VOICEINK_TCPP_BENCH_* variables pass through.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
scratch="${VOICEINK_TCPP_BENCH_SCRATCH:-${TMPDIR:-/tmp}/voiceink-tcpp-bench}"
report="${1:-$scratch/report.txt}"
mkdir -p "$scratch/models"

fetch() {
    local url=$1 path=$2 sha=$3
    if [[ ! -f "$path" ]] || ! shasum -a 256 -c <<< "$sha  $path" > /dev/null 2>&1; then
        curl --fail --location --silent --show-error --output "$path.partial" "$url"
        shasum -a 256 -c <<< "$sha  $path.partial" > /dev/null
        mv "$path.partial" "$path"
    fi
}

# Real speech: transcribe.cpp's 306-second sample at the runtime's pinned source commit.
audio="$scratch/dots-full.wav"
fetch "https://raw.githubusercontent.com/handy-computer/transcribe.cpp/856d7c10a1a864b900e066b7c9801edf373f5148/samples/dots-full.wav" \
    "$audio" 2e9c9335af977bb667c6a1893f5109c7219e2d616ab2b69f063a30891433109b

cohere_name=cohere-transcribe-03-2026-Q4_K_M.gguf
cohere_sha=0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb
installed_cohere="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/TranscribeCpp/cohere-transcribe/$cohere_name"
if [[ -f "$installed_cohere" ]] && shasum -a 256 -c <<< "$cohere_sha  $installed_cohere" > /dev/null 2>&1; then
    cohere="$installed_cohere"
else
    cohere="$scratch/models/$cohere_name"
    fetch "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/dfa4adebb64f3076b7b6b90b721275cc069cb421/$cohere_name" \
        "$cohere" "$cohere_sha"
fi
sensevoice="$scratch/models/SenseVoiceSmall-Q8_0.gguf"
fetch "https://huggingface.co/handy-computer/SenseVoiceSmall-gguf/resolve/4a08b8e900b38a977e32eb08d5d0697d6e72ba04/SenseVoiceSmall-Q8_0.gguf" \
    "$sensevoice" 6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29

passthrough=()
while IFS='=' read -r name value; do
    passthrough+=("TEST_RUNNER_$name=$value")
done < <(env | grep '^VOICEINK_TCPP_BENCH_' | grep -v '^VOICEINK_TCPP_BENCH_SCRATCH=' || true)

env GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf' \
    GIT_CONFIG_VALUE_0='https://github.com/' \
    TEST_RUNNER_VOICEINK_TCPP_BENCH_RESULT="$report" \
    TEST_RUNNER_VOICEINK_TCPP_BENCH_AUDIO="$audio" \
    TEST_RUNNER_VOICEINK_TCPP_BENCH_MODELS="${VOICEINK_TCPP_BENCH_MODELS:-$cohere,$sensevoice}" \
    ${passthrough[@]+"${passthrough[@]}"} \
    xcodebuild -quiet -project VoiceInk.xcodeproj -scheme VoiceInk \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath .local-build \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    -only-testing:VoiceInkTests/TranscribeCppThreadingBenchmarkTests test
printf 'report: %s\n' "$report"
