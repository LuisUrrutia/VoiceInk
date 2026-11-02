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
meeting is marked **Interrupted**.

## Files

Audio stays in VoiceInk's own data folder. Each build has a separate folder:

```
~/Library/Application Support/<bundle id>/Meetings/<meeting id>/
  meeting.json     state, title, timelines, dictation intervals
  system.wav       Them: 16 kHz mono PCM16
  microphone.wav   You: 16 kHz mono PCM16
```

The folders are readable only by your user. To find a meeting's audio, use the
folder button next to the meeting on the Meetings page.

Transcripts are written to the folder you choose. The default is
`~/Documents/VoiceInk Meetings`. Debug and local builds use
`VoiceInk Dev Meetings` and `VoiceInk Local Meetings` instead.

## Limits

- No real call has been recorded end to end with this implementation yet.
- The system tap captures every app's output, not only the call app.
- The two tracks have separate clocks. Their timelines realign every 5 seconds
  and after every gap, but drift between anchors is not corrected.
