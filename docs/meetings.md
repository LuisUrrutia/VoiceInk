# Meetings

Meetings records a call on this Mac. VoiceInk records your microphone as **You**
and the other participants' audio as **Them**, as two separate tracks. Meetings
is a Labs feature and is off until you turn it on in **Labs**.

The design adapts Hex's Meetings
(https://github.com/anomalyco/hex/blob/37c5dcdf81e3438ed4dad0396bd704c6b59d6eeb/docs/features/meetings.md,
MIT). The code is VoiceInk's own.

## Permissions

| Permission | Why | When VoiceInk asks |
|---|---|---|
| Microphone | The You track | Already granted for dictation |
| System Audio Recording | The Them track | When you turn on Meetings, press **Allow**, or record while undecided |

Screen Recording is not needed.

macOS has no public API that reads the System Audio Recording permission.
VoiceInk reads it with the private TCC query that Hex also uses. If macOS removes
that query, the Meetings page shows that VoiceInk cannot read the permission.
VoiceInk then records anyway, and macOS shows its prompt. A denied permission
records only silence, so VoiceInk refuses to start a meeting while it is denied.
To allow it later, open **System Settings › Privacy & Security › Screen &
System Audio Recording**.

## Recording

Start and stop a meeting from any of these:
- The Meetings page.
- The menu bar: **Record Meeting** and **Stop & Transcribe Meeting**.
- The **Record or Stop Meeting** shortcut.

While a meeting records:
- A small capsule shows its title and elapsed time. Hover over it to show
  **Stop**. You can turn the capsule off on the Meetings page. It asks macOS to
  stay out of screen sharing.
- The Mac does not go to idle sleep. The display can still sleep.
- **Dictation keeps working.** It leaves the call's volume and media alone, so you
  keep hearing the other participants. Each dictation's time span is recorded,
  so a later transcript does not show your dictation as something you said in
  the meeting.
- The microphone track follows your Audio settings: the selected microphone,
  closed-lid routing, microphone requirements, a temporary microphone and
  Bluetooth avoidance. When the input changes, recording continues in the same
  file.
- If the system audio tap stops delivering audio for 3 seconds, VoiceInk replaces
  it.

If you quit VoiceInk while a meeting records, both files are closed and the
meeting is marked **Interrupted**. If VoiceInk crashes or is forced to quit, the
next launch repairs the audio files. While a meeting records, VoiceInk saves its
progress every 30 seconds. Interrupted meetings are transcribed automatically.

## Call detection

While Meetings is on, VoiceInk notices calls in Zoom, Google Meet, Slack huddles,
Microsoft Teams and FaceTime. For each app, choose on the Meetings page:

| Choice | What happens when a call starts |
|---|---|
| **Ask** (default) | A small prompt offers **Record**, **Not now** and **Never for this app**. It disappears after 20 seconds without recording. |
| **Always record** | Recording starts, and a notice says it started automatically. |
| **Never offer** | Nothing. |

- A call is an app using the microphone for 2 seconds. After an offer or a
  recording, VoiceInk stays quiet about that app until it has been off the
  microphone for a minute.
- A recording never stops by itself. When the app leaves the call, VoiceInk asks
  whether to keep recording or stop and transcribe.
- Google Meet is recognized only in the front tab of a supported browser that
  VoiceInk is already allowed to control (System Settings › Privacy & Security ›
  Automation). VoiceInk never asks for that permission during a call. Once a
  Meet call records, switching tabs does not end it; the call ends when the
  browser stops using the microphone. Firefox is not supported.
- Turn off **Offer to record detected calls** to stop all detection.

## Transcripts

When a meeting stops, VoiceInk transcribes it on this Mac and writes a Markdown
file to the transcript folder. Transcription never uses a cloud provider; only
an optional summary, below, sends transcript text to your enhancement provider. VoiceInk uses
the current model when it is local (Parakeet or Whisper). Otherwise it uses a
downloaded local model, and prefers one that reports word times. Recording needs
such a model. VoiceInk loads its own copy of the model for the transcription and
releases it afterwards. A dictation started during transcription runs first.

```markdown
# Meeting Oct 15, 2026 at 2:30 PM

- **Date:** Thursday, October 15, 2026 at 2:30 PM
- **Duration:** 42:10

## Transcript

**You** · 00:01
Hi, can you hear me?

**Them** · 00:04
Yes, loud and clear.
```

- A file is never replaced. A second transcript of the same meeting gets
  ` (2)` and so on.
- The words you dictated during the meeting are left out of **You**.
- A failed transcription keeps the audio. Use **Transcribe** on the Meetings page
  to try again.
- **Copy** copies the file as it is now, including your edits. The menu bar
  offers **Copy Last Meeting Transcript**.

Turn on **Add a short summary** to put a summary of at most two sentences
above the transcript. The summary sends the transcript to the AI provider
selected for enhancement. Cloud providers, Ollama on another computer and Local
CLI commands can send it elsewhere. VoiceInk Refine only cleans up text, so it
cannot summarize. A long meeting is shortened to its opening, a few middle
passages and its ending. If the provider fails or takes longer than 90 seconds,
the transcript is written without a summary.

Parakeet TDT models place turns by word. Parakeet Unified and Nemotron place
turns by speech region, and Whisper by its segments.

## Files

Audio stays in VoiceInk's own data folder. Each build has a separate folder:

```
~/Library/Application Support/<bundle id>/Meetings/<meeting id>/
  meeting.json     state, title, timelines, dictation intervals
  system.wav       Them: 16 kHz mono PCM16
  microphone.wav   You: 16 kHz mono PCM16
```

The folders are readable only by your user. **Keep meeting audio** (7 days,
30 days by default, or forever) moves the audio of transcribed meetings to the
Trash after that period. Meetings that are not transcribed yet keep their audio.
Transcripts are never removed. To find a meeting's audio, use the
folder button next to the meeting on the Meetings page.

Transcripts are written to the folder you choose. The default is
`~/Documents/VoiceInk Meetings`. Debug and local builds use
`VoiceInk Dev Meetings` and `VoiceInk Local Meetings` instead.

## Limits

- No real call has been recorded end to end with this implementation yet.
- With speakers, your microphone also hears the other participants. VoiceInk
  removes those lines from **You** when the level pattern of both tracks shows
  delayed system audio, or when their words repeat what was just said.
  Talking over the other side is kept. The audio files are unchanged. The
  thresholds come from Hex, which tuned them on two calls, so some echo can
  remain and quiet replies can be removed.
- A track is read into memory for transcription, about 230 MB for each hour of
  audio.
- The system tap captures every app's output, not only the call app.
- The two tracks have separate clocks. Their timelines realign every 5 seconds
  and after every gap, but drift between anchors is not corrected.
