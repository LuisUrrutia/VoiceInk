# Language-aware model recommendations

VoiceInk suggests local speech models for a transcription language. The data is in
`VoiceInk/Features/ModelLibrary/Models/ModelRecommendations.swift`. It is adapted
from Hex (MIT, https://github.com/anomalyco/hex) at commit
`1018aecdbbc82a1dd655964fde800b7319ccf571`:

- Routing: `choices_for_runtime` in
  https://github.com/anomalyco/hex/blob/1018aecdbbc82a1dd655964fde800b7319ccf571/src/transcription_models.rs
- Evidence: the FLEURS test table in
  https://github.com/anomalyco/hex/blob/1018aecdbbc82a1dd655964fde800b7319ccf571/docs/plans/language-recommendations.md
  (Q8_0 GGUF artifacts through transcribe.cpp; WER %, CER % for `zh`, `yue`,
  `ja`, `ko` and `th`). Hex treats differences under about 1.5 points as ties.

VoiceInk did not measure these models itself. A suggestion repeats Hex's
comparison of Hex's own catalog. It makes no claim about VoiceInk models that Hex
did not compare.

## Where suggestions appear

- **Models > Speech Models > Local:** a badge (Recommended, Fastest or Most
  accurate) marks suggested models for the default mode's languages. A mode
  without its own languages uses the global language setting. With Default Order,
  suggested models come first in Hex's order, and the other models keep their
  catalog order. Speed, accuracy and name sorts, the installation filters and
  search do not change. A caption above the list names the language.
- **Mode editor > Model menu:** usable suggested models come first, under
  "Suggested for *language*", for the mode's own languages.

Multiple selected languages use Hex's `auto` entry. VoiceInk transcribes them
with automatic detection. A model must support every selected language and
multiple selection, so only Whisper Large v3 Turbo qualifies. Locale codes such as
`es-ES` match their language. Hex's Filipino (`fil`) matches Whisper's `tl`.

## Model mapping

| Hex model | VoiceInk model (`name`) | Artifact difference |
| :--- | :--- | :--- |
| Whisper large-v3-turbo | Large v3 Turbo (`ggml-large-v3-turbo`) | whisper.cpp ggml instead of Q8_0 GGUF; same weights |
| Parakeet v3 | Parakeet V3 (`parakeet-tdt-0.6b-v3`) | FluidAudio Core ML instead of Q8_0 GGUF |
| Parakeet Unified English | Parakeet Unified (`parakeet-unified-0.6b`) | FluidAudio Core ML, int8 encoder |
| Cohere Transcribe | Cohere Transcribe (`cohere-transcribe`) | Q4_K_M from the same repository revision, not Q8_0 |
| SenseVoice Small | SenseVoice Small (`sensevoice-small`) | The same Q8_0 file (identical SHA-256) |

The quantized Large v3 Turbo (`q5_0`) is not marked: Hex measured a different
quantization.

## Suggestions per language

| Language | VoiceInk suggestion | Hex evidence (FLEURS) | Hex entries VoiceInk omits |
| :--- | :--- | :--- | :--- |
| Auto-detect, multiple languages | Recommended: Large v3 Turbo | 30-language median: Whisper 8.6, Qwen 0.6B 13.3 | Fastest: Qwen3-ASR 0.6B |
| English | Recommended: Parakeet Unified; Most accurate: Cohere | Unified 3.99; Cohere 1.27 on LibriSpeech clean, 6.26 Open ASR average. Hex keeps Unified for streaming | Recognition hints: Whisper |
| Mandarin (`zh`) | Fastest: SenseVoice | SenseVoice 10.12 | Recommended: Qwen3-ASR 0.6B (7.57); hints: Whisper (8.50) |
| Cantonese, Korean | None | Qwen 0.6B: yue 7.91, ko 5.82 | Recommended: Qwen3-ASR 0.6B; hints: Whisper (yue 34.62, ko 5.24) |
| Japanese | Recommended: Large v3 Turbo; Fastest: SenseVoice | Whisper 4.82, SenseVoice 7.63, Qwen 0.6B 8.61 | None |
| Greek | Recommended: Cohere | Cohere 8.96, Whisper 13.26, Parakeet v3 35.33 | Hints: Whisper |
| Finnish, Swedish, Danish | Recommended: Large v3 Turbo; Fastest: Parakeet V3 | Whisper fi 8.29, sv 8.72, da 13.60; v3 fi 13.30, sv 15.25, da 18.64 | None |
| Maltese | Recommended: Parakeet V3 | v3 20.63, Whisper 70.92 | None |
| Arabic | Recommended: Large v3 Turbo; Most accurate: Cohere | Cohere 13.60, Whisper 15.48, Qwen 0.6B 24.51 | None |
| Turkish, Malay, Filipino (`tl`), Persian, Macedonian | Recommended: Large v3 Turbo | Whisper tr 6.97, ms 8.64, fil 12.08, fa 30.56, mk 17.85 | None |
| Bengali | Recommended: Large v3 Turbo | Not measured; Whisper is the only Hex model that supports it | None |
| Vietnamese | Most accurate: Cohere | Cohere 7.39, Qwen 0.6B 9.32, Whisper 9.48 | Recommended: Qwen3-ASR 0.6B; hints: Whisper |
| Hindi, Indonesian, Thai | None | Qwen 0.6B hi 12.68, id 8.49, th 8.81 | Recommended: Qwen3-ASR 0.6B; hints: Whisper |
| Bulgarian, Croatian, Czech, Dutch, Estonian, French, German, Hungarian, Italian, Latvian, Lithuanian, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Ukrainian | Recommended: Parakeet V3 | Hex's current routing keeps v3. In the same table, Whisper ties or beats v3 in several of these languages (for example nl 5.98 against 7.66, pl 5.81 against 7.37) | Hints: Whisper |

Other languages have no suggestions: Hex has no evidence for them.

## Not adopted

- **Models VoiceInk does not ship:** Qwen3-ASR 0.6B (Hex's Recommended entry for
  Mandarin, Cantonese, Korean, Vietnamese, Hindi, Indonesian and Thai, and Fastest
  for Auto), QwenCleo-ASR 1.7B (listed for Arabic without a badge), and Underdog
  Bark 3.0 Pro and Clean (listed for English without a badge). VoiceInk does not
  substitute another model for these entries.
- **Hex's "Recognition hints" role:** it marks Whisper because Whisper accepts
  vocabulary hints, not because of a benchmark result. It would mark Whisper for
  Cantonese at 34.62% CER.
- **Hex's planned Phase B models** (Parakeet Ultra, Canary 1B v2, Qwen3-ASR 1.7B)
  are not in Hex's shipped routing. VoiceInk's Parakeet Ultra stays unmarked.
- **Models without Hex evidence:** Parakeet V2 and Ultra, Nemotron Latin and
  Multilingual, Whisper Tiny, Base, Large v2, Large v3 and Large v3 Turbo
  (quantized), Apple Speech, imported models, and cloud and custom models.

## Language-changing model switches

Selecting a model in the mode editor that cannot keep the mode's languages opens
a confirmation before the switch, with the language that replaces them. Examples:
"Parakeet V2 doesn't support Greek, so this mode's language changes to English."
and "Cohere Transcribe transcribes one language at a time, so this mode's language
changes to Spanish." Cancel keeps the current model and languages. Switches that
keep the languages apply immediately, as before.
