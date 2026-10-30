# Parakeet vocabulary boost (experimental)

Parakeet decodes speech without knowledge of the Dictionary, so names such as
"VoiceInk" can come out as "Voice Inc". This experimental option rescores the
final Parakeet transcript with FluidAudio's CTC keyword spotter. A separate
English CTC model (`FluidInference/parakeet-ctc-110m-coreml`, about 100 MB)
looks for Dictionary terms in the same audio. A term replaces transcript words
only when the CTC model's acoustic evidence prefers it.

## Use it

1. Open the settings panel on the **Models** page, then **Transcription >
   Vocabulary Boost**.
2. Turn on **Dictionary Boost for Parakeet (Experimental)**. The CTC model
   downloads only at this point, into the shared FluidAudio model cache
   (`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`).
   Delete it from the same section.
3. Add the terms to **Dictionary > Vocabulary**. A Word Replacement whose
   replacement equals a vocabulary term supplies spellings that the rescorer
   also accepts for that term. For example, the replacement `Voice Inc` →
   `VoiceInk` makes "Voice Inc" an alias of `VoiceInk`.

The preference is `IsParakeetVocabularyBoostEnabled` in the editable
configuration file and defaults to `false`.

## Behavior and limits

- Applies to Parakeet v2, v3 and Ultra batch transcription, and to the batch
  fallback of a short realtime recording. Text that realtime streaming already
  confirmed is not rescored. Parakeet Unified, Nemotron, Whisper and cloud models
  are unchanged.
- Rescoring uses the post-VAD samples that Parakeet decoded and their token
  timings. When the model is missing, loading or rescoring fails, or no term
  qualifies, VoiceInk keeps the unboosted text. Word Replacements, filler
  removal, formatting and AI enhancement then run as before.
- Recording preparation loads the installed model for batch transcription; it
  never downloads it. The loaded model and rescorer persist across recordings
  until the vocabulary changes, the option is turned off or the model is deleted.
  Expect about 64 MB more memory while it is loaded.
- Settings are conservative: context-biasing weight 0, minimum similarity 0.7,
  terms of at least three characters, at most 256 terms (alphabetical order) and
  no acoustic-only rescue. FluidAudio's defaults replaced many correctly spoken
  words in a 500-dictation study:
  https://github.com/FluidInference/FluidAudio/issues/967.
- The CTC tokenizer is English-only. Terms with accents or `ñ` are likely to be
  weak, and boosting does not fix English phrases that are not in the Dictionary.
- A term that is also an ordinary word, such as `Orca` in Spanish, can replace
  that word with the Dictionary spelling.

## Measure it

Do not enable the option permanently before a measurement on your own voice. The
`voiceink-vocab-eval` tool decodes each file once, then compares the plain and
the boosted transcript for the same decode:

```sh
make vocab-eval
cli/parakeet/.build/release/voiceink-vocab-eval --help
```

### Record a set

Record with the microphone and room that you use for dictation. The tool reads
WAV, M4A and other AVFoundation formats.

- **Term sentences (20–30):** sentences in your usual language that contain your
  Dictionary terms as you say them during dictation. Include each important term
  in at least two sentences and in different positions.
- **Control sentences (about 20):** ordinary sentences without any term. Include
  words that sound like your terms, for example "efecto" for `Effect`, "hoy" for
  `Roy` or "voy a cambiar" for `VoiceInk`. Every change to a control is a false
  replacement candidate.

### Write the manifest

The manifest is tab-separated: audio file, expected terms separated by `;` (repeat
a term for each mention, leave empty for a control) and an optional reference
text. Relative paths resolve against the manifest folder. Lines that start with
`#` and a first `file` header line are ignored.

```text
file	expected_terms	reference
t01.m4a	VoiceInk	Ayer abrí VoiceInk para dictar el correo.
c01.m4a		Hoy voy a cambiar la configuración del correo.
```

### Run and read the report

Export the Dictionary from the settings panel on the **Dictionary** page
(**Export Dictionary**) and run:

```sh
cli/parakeet/.build/release/voiceink-vocab-eval \
  --manifest manifest.tsv --dictionary dictionary.json \
  --runs 3 --report report.json
```

`--term TEXT[=ALIAS,ALIAS]` adds terms that are not in the export. Use `--cbw`,
`--min-similarity`, `--min-term-length`, `--max-terms`, `--margin` and
`--acoustic-rescue` to compare other settings. The defaults match the app.

The summary reports:

- **Changed transcripts:** term files and controls whose boosted text differs.
- **Expected-term hits:** expected mentions found in the plain and in the boosted
  text, both for raw ASR text and after the app's filler removal, formatting and
  Word Replacements.
- **Unexpected term insertions:** term mentions that appear in the boosted text
  but in neither the plain text nor the expected terms.
- **Nondeterministic files:** files whose rescoring differed across `--runs`.
- **Timing:** total audio, ASR and CTC rescoring time, and the one-time CTC load.

`report.json` contains every transcript and every applied replacement. Review
the changed controls and term files by hand: a changed transcript can be a
correct fix, an unrelated change, or a correct term that removed a neighboring
word.
