# Annotate

Annotate records your screen while you talk, so you can show an AI agent what is
wrong instead of describing it. Annotate is a Labs feature and is off until you
turn it on in **Labs**. The design adapts Hex's Annotate
(https://github.com/anomalyco/hex/blob/37c5dcdf81e3438ed4dad0396bd704c6b59d6eeb/docs/features/capture.md,
MIT). It does not need OpenCode or Scrawl.

## Recording

1. Press the **Start or Stop Annotation** shortcut, or press **Annotate** on the
   Annotations page.
2. Show the problem on the display under the pointer and say what you see.
3. Press the shortcut again, or **Stop** in the capsule at the bottom of the
   screen. **Cancel** discards the annotation.

To point at something, hold **Shift** alone, or turn on the pen in the capsule,
and draw. The ink fades after a moment and is not part of the movie. VoiceInk
keeps every stroke with its time and position, and notes each click and scroll.
It never records keystrokes.

An annotation lasts at most 20 minutes. VoiceInk's own windows are not recorded.
While you annotate, dictation waits, and a meeting cannot start.

| Permission | When VoiceInk asks |
|---|---|
| Screen Recording | The first time you annotate |
| Microphone | Already granted for dictation |

## What an agent receives

When you stop, VoiceInk transcribes the narration on this Mac with the same
local model as Meetings. It then copies a summary to the clipboard. Paste it
into a local agent, such as Claude Code or Codex in a terminal. The summary
names the bundle's folder, so the agent can open the files:

```
~/Library/Application Support/<bundle id>/Annotations/<id>/
  recording.mp4     the screen, H.264, long edge at most 2,560 pixels
  narration.wav     your voice, 16 kHz mono
  annotation.json   timestamps, display size, transcript with word times
  summary.md        the text that was copied
```

Coding agents read text and images, not video. So VoiceInk picks up to 12
moments, depending on length: when you finished drawing, after a click, when
you said "look" or "here", or when the screen changed. It saves them as images
with your ink, clicks and a number drawn on them:

```
  contact-sheet.png every keyframe in one image, numbered
  frames/           each keyframe at full size
```

The summary asks the agent to look at those images first and lists each
keyframe with what you said at that moment.

## Sending it to an agent

Every annotation copies its summary. Paste it into an agent that runs in a
terminal and can read files, such as Claude Code or Codex. It keeps your session
and its context. For a chat app that accepts images, use the camera button on
the Annotations page to copy the contact sheet as an image.

To hand every annotation to an agent automatically, set **Agent command** on the
Annotations page. VoiceInk runs it in your login shell when an annotation is
ready, with the summary on standard input and these variables:

| Variable | Value |
|---|---|
| `VOICEINK_ANNOTATION_DIR` | the bundle folder |
| `VOICEINK_ANNOTATION_SUMMARY` | `summary.md` |
| `VOICEINK_ANNOTATION_CONTACT_SHEET` | `contact-sheet.png`, when it exists |
| `VOICEINK_ANNOTATION_IMAGES` | the contact sheet, then each keyframe, one path per line |

A command starts a new agent session without the context of a session you have
open. Its output is saved as `agent-output.txt` in the bundle, and **Stop
Agent** ends it. Turning Annotate off or quitting VoiceInk also ends it, and no
command starts while Annotate is off. The command must finish within the time
limit, five minutes by default. Examples, checked against `claude --help` and `codex exec --help`
(replace the project path):

```sh
cd ~/Projects/my-app && claude -p --add-dir "$VOICEINK_ANNOTATION_DIR" \
  "Read $VOICEINK_ANNOTATION_SUMMARY and the images it names, then explain what the annotation asks for."
```

```sh
codex exec -C ~/Projects/my-app -i "$VOICEINK_ANNOTATION_CONTACT_SHEET" \
  "Follow the annotation below. Its contact sheet is attached."
```

Codex appends the summary from standard input to the prompt. Both agents use
their own sign-in and network access; VoiceInk only starts them.

## Retention

**Keep annotations** removes the movie and the narration after 7 days, and the
whole bundle after 30 days. The images, the summary and `annotation.json` stay
until the bundle is removed. You can also choose 30 and 90 days, or **Forever**.
An annotation that is recording, processing or running its command is never
removed. A movie that cannot be removed, for example a locked file, is tried
again on the next hourly pass.
