# Editable configuration

VoiceInk loads `config.jsonc` at startup and automatically saves preferences changed
in the app. The first launch creates the file from the existing preferences and
dictionary. Open **Settings > Portable Configuration > Show in Finder** to find
the file used by your build.

The standard app uses `$XDG_CONFIG_HOME/voiceink/config.jsonc`. When
`XDG_CONFIG_HOME` is unset, empty or relative, the base directory is `~/.config`.
This follows https://specifications.freedesktop.org/basedir/latest/.

Development builds keep their existing isolation:

- Debug (`VoiceInk Dev.app`): `$XDG_CONFIG_HOME/voiceink/dev/config.jsonc`.
- `LOCAL_BUILD` (`make local`): `$XDG_CONFIG_HOME/voiceink/local/config.jsonc`.
- Standard Release: `$XDG_CONFIG_HOME/voiceink/config.jsonc`.

Each path uses the same `~/.config` fallback. Finder launches inherit the login
session's environment, not variables set only in a terminal shell. The path shown
in Settings is authoritative for the running process.

## Edit or move your settings

1. Quit VoiceInk before editing or replacing its configuration file.
2. Edit the generated file, or copy it to another machine's matching configuration
   path. JSONC accepts `//` and `/* ... */` comments and trailing commas. Use UTF-8.
3. Reopen VoiceInk. It validates the file before applying the preferences and
   dictionary, then initializes the model, mode and shortcut services.

On a new machine, local permissions and setup still apply. If the file provides
`modeConfigurationsV2` (including an empty list), onboarding skips its starter-mode
demonstrations and retains your modes, shortcuts, default and active selection.

The file uses schema version `1`. A small configuration can contain only the
preferences you want to override:

```jsonc
{
  "schemaVersion": 1,
  "preferences": {
    // Ordered explicit languages; this takes precedence over SelectedLanguage.
    "SelectedLanguages": ["es", "en"],
    "IsVADEnabled": true,
    "AppendTrailingSpace": true,
    "IsTextFormattingEnabled": true,
    "restoreClipboardAfterPaste": true,
    "clipboardRestoreDelay": 2,
  },
}
```

Omitted preferences retain their current values. A preference set to `null`
removes its saved override so the app's normal default applies. An omitted
`dictionary` leaves the current dictionary alone. When `dictionary` is present,
its `sections`, `vocabulary` and `replacements` lists describe the complete desired
dictionary; empty lists intentionally clear those entries. Loading updates existing
entries in place where their identities match and commits dictionary changes in one
SwiftData save. History and recordings are unaffected.
An app dictionary edit writes the complete dictionary, even if the original file
omitted it. Editing a map such as `CustomLanguagePrompts` also saves that entire
preference, retaining its other entries.

```jsonc
{
  "schemaVersion": 1,
  "dictionary": {
    "sections": [{
      "id": "65C07CF6-82C1-43D1-990F-A0D919B6632E",
      "name": "Technology",
      "description": "Product and framework names",
    }],
    "vocabulary": [{
      "term": "VoiceInk",
      "sectionID": "65C07CF6-82C1-43D1-990F-A0D919B6632E",
    }],
    "replacements": [{
      "sources": ["voice ink", "vois ink"],
      "replacement": "VoiceInk",
    }],
  },
}
```

Generated dictionary entries also include `addedAt` (Unix time in seconds), and
replacement rules include their `id`. Keep these fields when moving a file between
machines. They are optional when adding entries by hand. Vocabulary membership
references section UUIDs; replacement sources are separate phrases, without commas.
Duplicate identities and duplicate sources within one rule are rejected. Legacy
rules sharing sources or forming cycles are preserved and use the app's existing
ordered replacement behavior. Replacement targets trim surrounding whitespace and
normalize Unicode on both insertion and update.

## Included preferences

The `preferences` object uses the app's existing preference names. Stored JSON
archives appear as editable objects and arrays, not Base64 strings. Start with the
generated file to keep the complete structure and stable UUIDs.

- **Speech models:** `CurrentTranscriptionModel`, `SelectedLanguages`,
  `SelectedLanguage`, `IsVADEnabled`, `CustomLanguagePrompts`,
  `CloudTranscriptionTimeout`, `PrewarmModelOnWake` and text formatting.
  Keep the generated provider-qualified model selection key.
- **Enhancement:** provider-specific `SelectedModel` and `CustomModelID` values,
  `selectedAIProvider`, `customPrompts`, `customCloudModels`, `customAIProviders`,
  Ollama endpoint/model, Local CLI command/template/timeout, short-enhancement
  settings, request timeout/retry and filler words.
- **Modes:** `modeConfigurationsV2` includes names, icons, enabled/default state,
  app/URL/word triggers, prompts, speech and enhancement selections, languages,
  realtime settings, context capture and output commands. `activeConfigurationId`
  retains the selected mode. `userAddedEmojis` retains custom icons.
- **Audio:** input mode, saved microphone UID/model UID, `prioritizedDevices`
  including microphone/application requirements, recording sound selections,
  mute/pause preferences and resume delay. Temporary microphone overrides remain
  temporary.
- **Shortcuts:** primary/secondary selections and recording modes, plus
  `Shortcut_<action>` and `Shortcut_mode_<UUID>` objects. `_cleared` flags preserve
  explicitly cleared shortcuts. Bindings use the editor's typing/reserved-key
  restrictions; conflicts are checked against the final settings, including
  unchanged shortcuts omitted from the file.
- **Other settings:** appearance/language, Dock/menu-bar visibility, recorder
  style/live text, paste method and original target, clipboard restoration and
  remote push command, Auto Send, Auto Learn provider/model/schedule, dictionary
  sorting, retention preferences, automatic update checks, announcements and playback rate.

The supported names and value types are defined in
`VoiceInk/Infrastructure/Persistence/Configuration/ConfigurationPreferences.swift`.
Unknown preference names and unsupported schema versions are rejected rather than
silently ignored.

API keys remain in Keychain and must be configured separately on another machine.
The file does not contain downloaded models, custom sound files, History, audio,
statistics, permissions, login-item registration, onboarding progress or transient
window state. Model and provider definitions do not download models or establish
provider credentials. User-written prompts, endpoints and shell commands are saved
as entered, so review their contents before publishing a configuration file.

## Saving and recovery

Changes from the app are coalesced over 350 ms and flushed on normal termination.
Files are replaced atomically with owner-only read/write permissions. Symbolic
links are followed so an existing dotfiles link remains in place.

Unchanged content is not rewritten. Updates preserve comments and formatting
around unchanged values and inside objects whose existing members remain. A list
whose length changes, or an object whose members are removed, is serialized again;
comments inside that replaced value are not retained. Put durable notes beside the
containing preference or section.

If the file is changed or deleted while VoiceInk is open, saving pauses and Settings
shows an error. Quit and reopen to load the external version. External changes are
not hot-reloaded during a recording. Invalid or unreadable files remain untouched;
the app uses its existing preferences and shows the error at launch and in Settings.
Fix the file and reopen to resume saving. An unavailable persistent store also
disables configuration syncing so an in-memory fallback cannot overwrite the file.

The existing manual **Backup** import/export remains available. Its format is
separate from this configuration schema.
