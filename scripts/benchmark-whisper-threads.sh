#!/usr/bin/env bash
# Opt-in whisper.cpp thread-count/QoS benchmark (WhisperThreadingBenchmarkTests).
# Downloads into a scratch directory outside app persistence. The app catalog has no
# Whisper checksums, so files are pinned to a Hugging Face revision and its LFS SHA-256.
# `--prepare` only downloads. Extra VOICEINK_WHISPER_BENCH_* variables pass through.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
scratch="${VOICEINK_WHISPER_BENCH_SCRATCH:-${TMPDIR:-/tmp}/voiceink-whisper-bench}"
prepare_only=false
if [[ "${1:-}" == "--prepare" ]]; then
    prepare_only=true
    shift
fi
report="${1:-$scratch/report.txt}"
# Separate directories: whisper.cpp also loads the Turbo Core ML encoder for the Q5_0 file
# when both sit together, while an install with only Q5_0 encodes on Metal.
mkdir -p "$scratch/turbo" "$scratch/turbo-q5_0"

fetch() {
    local url=$1 path=$2 sha=$3
    if [[ ! -f "$path" ]] || ! shasum -a 256 -c <<< "$sha  $path" > /dev/null 2>&1; then
        curl --fail --location --silent --show-error --output "$path.partial" "$url"
        shasum -a 256 -c <<< "$sha  $path.partial" > /dev/null
        mv "$path.partial" "$path"
    fi
}

# Real speech: transcribe.cpp's 306-second sample, as in the transcribe.cpp benchmark.
audio="$scratch/dots-full.wav"
fetch "https://raw.githubusercontent.com/handy-computer/transcribe.cpp/856d7c10a1a864b900e066b7c9801edf373f5148/samples/dots-full.wav" \
    "$audio" 2e9c9335af977bb667c6a1893f5109c7219e2d616ab2b69f063a30891433109b

# The app downloads these names from ggerganov/whisper.cpp `main`; pin today's revision.
hf="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1"
turbo="$scratch/turbo/ggml-large-v3-turbo.bin"
fetch "$hf/ggml-large-v3-turbo.bin" "$turbo" 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
quantized="$scratch/turbo-q5_0/ggml-large-v3-turbo-q5_0.bin"
fetch "$hf/ggml-large-v3-turbo-q5_0.bin" "$quantized" 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
# The app installs the Core ML encoder with the non-quantized Turbo model.
encoder="$scratch/turbo/ggml-large-v3-turbo-encoder.mlmodelc"
if [[ ! -f "$encoder/.verified" ]]; then
    zip="$scratch/encoder.zip"
    fetch "$hf/ggml-large-v3-turbo-encoder.mlmodelc.zip" "$zip" 84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a
    rm -rf "$encoder" "$scratch/encoder-staging"
    ditto -x -k "$zip" "$scratch/encoder-staging"
    mv "$scratch/encoder-staging/ggml-large-v3-turbo-encoder.mlmodelc" "$encoder"
    rm -rf "$scratch/encoder-staging" "$zip"
    touch "$encoder/.verified"
fi

if $prepare_only; then
    printf 'prepared: %s\n' "$scratch"
    exit 0
fi

passthrough=()
while IFS='=' read -r name value; do
    passthrough+=("TEST_RUNNER_$name=$value")
done < <(env | grep '^VOICEINK_WHISPER_BENCH_' | grep -Ev '^VOICEINK_WHISPER_BENCH_(SCRATCH|RESULT|AUDIO|MODELS)=' || true)

env GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf' \
    GIT_CONFIG_VALUE_0='https://github.com/' \
    TEST_RUNNER_VOICEINK_WHISPER_BENCH_RESULT="$report" \
    TEST_RUNNER_VOICEINK_WHISPER_BENCH_AUDIO="$audio" \
    TEST_RUNNER_VOICEINK_WHISPER_BENCH_MODELS="${VOICEINK_WHISPER_BENCH_MODELS:-$turbo,$quantized}" \
    ${passthrough[@]+"${passthrough[@]}"} \
    xcodebuild -quiet -project VoiceInk.xcodeproj -scheme VoiceInk \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath .local-build \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    -only-testing:VoiceInkTests/WhisperThreadingBenchmarkTests test
printf 'report: %s\n' "$report"
