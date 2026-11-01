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
