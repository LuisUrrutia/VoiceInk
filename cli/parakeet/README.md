# Headless Parakeet transcription

`voiceink-cli` transcribes audio files locally with installed Parakeet v2 or v3
models. It does not launch VoiceInk, download models, upload audio, enhance text,
paste, or write History. Runtime model loading uses FluidAudio's offline mode and
local-only Core ML loaders.

## Build and run

Requirements: macOS 15+, Apple Silicon for Parakeet, Xcode with Swift 6.0 or later,
and a complete Parakeet model installed through VoiceInk Models. The package pins
the app's FluidAudio revision; it does not change the app's dependencies.

From the checkout root:

```sh
make cli
cli/parakeet/.build/release/voiceink-cli --help
make test-cli
```

No installation is required. These examples assume the named audio files exist:

```sh
cli/parakeet/.build/release/voiceink-cli meeting.m4a
cli/parakeet/.build/release/voiceink-cli meeting.m4a --format srt --output meeting.srt
cli/parakeet/.build/release/voiceink-cli one.wav two.mp3 --format json --output transcripts --skip-existing
cli/parakeet/.build/release/voiceink-cli interview.wav --lang es --namespace development
cli/parakeet/.build/release/voiceink-cli --dictionary dictionary.json -- --dash-leading.wav
```

## Options and output

`--format` (`-f`) accepts `txt`, `json`, or `srt`; the default is `txt`.
A single input writes its transcript to stdout unless `--output` (`-o`) is given.
An existing output directory receives a file named after the input without its
extension. Multiple inputs require an output directory, which is created when
needed. Inputs with colliding output names are rejected before processing. Output
paths cannot alias audio inputs or explicit settings/dictionary snapshots, including
symlinks and hard links. Writes are atomic. `--skip-existing` preserves existing
regular output files, including files created concurrently, and does not load a
model or settings when every output is already present.

Progress and fallback notices go to stderr. `--quiet` (`-q`) suppresses them;
errors remain visible. Exit codes are 0 for complete success, 1 for processing or
settings failures (the batch continues), and 2 for invalid invocation or output
collisions. `--help`, `--version`, and `--` are supported. Zero-sample and corrupt
inputs fail. Valid silent audio produces an empty transcript.

`--model v2|v3` defaults to v3. `--model-directory PATH` selects an exact directory
containing that version's compiled model files and `parakeet_vocab.json`; otherwise the
FluidAudio cache is used. Missing or incompatible models fail locally.
`--lang auto|CODE` overrides the saved `SelectedLanguage` (default `en`). The v3
codes are the current FluidAudio script hints listed in the invalid-language error;
they are not a guarantee that recognition is restricted to a language. V2 accepts
`auto` or `en`; its effective language is English. Unsupported saved languages use
automatic decoding.

## Read-only preferences and dictionary

`--namespace production|development|local` defaults to production:

- Production preferences/store identity: `com.prakashjoshipax.VoiceInk`.
- Development preferences/store identity: `com.prakashjoshipax.VoiceInk.dev`.
- Local builds share production preferences, as the app does, but use the isolated
  `com.prakashjoshipax.VoiceInk.local` store directory.

The CLI reads one CFPreferences domain snapshot without registering or saving
values. `--preferences PATH` instead reads an explicit plist snapshot. Missing
settings use the same defaults registered by the app: VAD and paragraph formatting
enabled, language `en`, and the configured/default filler list. Flags `--no-vad`,
`--no-format`, `--keep-fillers`, and `--no-replacements` override settings in memory.
This fork has no additional punctuation/lowercase cleanup preference, so the CLI
does not introduce those reference-fork settings.

For replacements, export Dictionary from the desired app build and pass the
resulting file with `--dictionary PATH`. The existing app export collects the
dictionary through its ModelContext and saves one atomic JSON artifact. The CLI
reads that artifact once; it never opens `dictionary.store`, queries SwiftData's
private tables, or copies a live store and WAL. The export is explicit so one
namespace cannot silently load another namespace's dictionary. Without an export,
replacements are empty and a progress notice explains how to supply them.

Dictionary schema versions 1 and 2 are supported. Replacement entries use
`sources`, `replacement`, and optional `createdAt`. All app-exported rules are
active under the fork's existing policy. A CLI snapshot can additionally set
`"enabled": false` on an entry. Empty sources are ignored. Matching, variant
ordering, Unicode boundaries, and literal replacement text share the app's pure
replacement plan. The CLI does not change the app's persisted compatibility field
`isEnabled` or its all-rules-active policy.

## Audio pipeline and timestamps

The decoder reads supported AVFoundation formats without assuming a WAV header
size. One AVAudioConverter spans the whole file; every source frame is fed once,
channels are averaged, and the converter is drained at EOF. AVAssetReader is the
fallback for media containers. No external process or ffmpeg is invoked. Files
unsupported by both decoders must be converted separately. Source buffers are
bounded; inference keeps the decoded 16 kHz mono samples in memory, with a two-hour
limit. Split longer files first. Original amplitude is preserved rather than using
the app importer's intermediate peak-normalized Int16 WAV.

Cached Silero VAD uses threshold 0.7. A missing/unloadable VAD model or a segmentation
failure produces a notice and uses the whole file, without downloading. Empty
speech intervals produce empty output. Short speech is padded to FluidAudio's
minimum sample count; timestamps are clamped to the original audio. Parakeet then
runs, followed by TextNormalizer, the shared tag/bracket/filler filter, optional
shared paragraph formatting, and the shared replacement plan. No additional
one-second tail or 20-second VAD threshold from the reference fork is imposed.

JSON includes `text`, `segments` (`start`, `end`, `text`), `duration`,
`speechDuration`, and `vadApplied`. Seconds refer to the original file, even when
speech intervals are concatenated for inference. At a concatenation join, a start
maps to the next speech interval and an end maps to the preceding interval; padded
tail times map to the final speech end. Cues can span an omitted silence when their
tokens straddle intervals. SRT uses rounded millisecond timestamps and nonoverlapping,
ordered cues. If the model supplies no token timings, one cue spans the speech
range and a notice marks that fallback.

The complete `text` is cleaned as one document. Timed segments group original model
tokens into approximately six-second cues and apply normalization/filtering and
replacements independently, without paragraph formatting. Thus concatenating
segment text need not equal `text`: replacements and normalization that cross cue
boundaries only apply to the complete transcript. The command does not claim word
alignment for edited text.

## Shared implementation and checks

The package's `TranscriptionText` sources are symlinks to the app's pure defaults,
filter, formatter, replacement plan, variant parser, and persistence namespace policy. Keep them as links so both
callers compile the same algorithms. No AppKit launch or GUI singleton is required.
`make test-cli` covers parsing/exit codes, snapshots/defaults/flags, Unicode,
SRT ordering, VAD time mapping, resampling duration/tail, corrupt/empty inputs,
batch continuation, atomic writes, aliases/collisions, and skip-before-loading.
`SharedTranscriptionTextTests` covers app wrapper parity and replacement persistence
policy. Both paths are included in the fork synchronization checker.

Source intent: https://github.com/NavNab/VoiceInk/commit/b41acbbc65b9e7e7e8913eb86c16be7ddea54cad.
This checkout has no older Whisper shell CLI to retire. The reference's model pin,
macOS 14 target, copied cleanup algorithms, private SQLite access, automatic
installation helper, and fork-specific cleanup settings are not carried over.
