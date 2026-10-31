# Read History from agents

`voiceink-history` lets terminal tools and agents read completed dictations from
History on this Mac. It is adapted from Hex's `hex history --json` and read-only
`hex mcp` server. Unlike Hex, it never reads VoiceInk's files: the running app
answers each request over a local socket, so the command works only while
VoiceInk runs with agent access enabled.

## Enable access

In VoiceInk, open History, then History Settings, and turn on **Allow Local Agents
to Read History** under Agent Access. The setting is off by default. It belongs
to this Mac: the XDG configuration file and backups do not carry it, so restoring
settings never opens the channel. Turning it off closes the socket at once.

## Build and run

From the checkout root:

```sh
make history-cli
cli/parakeet/.build/release/voiceink-history --help
make test-cli
```

```sh
voiceink-history list --since 3d
voiceink-history list --limit 50 --json
voiceink-history search 'release schedule' --since 2026-10-20 --until 2026-10-21 --json
voiceink-history show 6F9619FF-8B86-D011-B42D-00C04FC964FF
voiceink-history list --namespace development
```

- `list` returns completed entries, newest first. `search QUERY` keeps entries
  whose original or enhanced text contains QUERY, ignoring case and diacritics,
  as the History search does. `show ID` returns one entry by UUID.
- `--limit` accepts 1–200 (default 20). `--since` is inclusive; `--until` is
  exclusive. TIME accepts `90m`, `36h`, `3d`, `2w`, `now`, `today`, `yesterday`,
  `YYYY-MM-DD` (local midnight), an RFC 3339 date-time, or Unix seconds.
- Results use History's order (timestamp, then UUID, newest first). When more
  entries match, the response has `next_cursor`; pass it as `--cursor` with the
  same filters to read older entries. Equal timestamps are never skipped or
  repeated across pages.
- Pending, canceled and failed recordings are excluded. Entries from builds that
  predate transcription statuses count as completed.
- `--namespace production|development|local` selects the release app, the Debug
  `VoiceInk Dev.app`, or a `LOCAL_BUILD`. Each build has its own socket and store.

Exit codes: 0 success (including no matches), 1 failed request or unknown ID,
2 invalid invocation, 3 VoiceInk is not running or agent access is off.

## JSON version 1

`--json` writes one object to stdout; errors go to stderr. Consumers should ignore
unknown fields. Nullable fields are present as `null`.

```ts
type Page = {               // list, search
  version: 1
  entries: Entry[]
  truncated: boolean        // more entries match; read them with next_cursor
  next_cursor: string | null // opaque
}
type Show = { version: 1; entry: Entry }
type Entry = {
  id: string                // UUID
  timestamp: string         // RFC 3339 UTC with milliseconds
  original_text: string     // transcription before enhancement
  enhanced_text: string | null // null without enhancement or when it failed
  mode: string | null
  transcription_model: string | null
  enhancement_model: string | null
  prompt: string | null
  duration_ms: number       // recording length
  transcription_duration_ms: number | null
  enhancement_duration_ms: number | null
}
```

The enhancement request context (clipboard, selection and screen text) and audio
file paths are never returned.

## MCP server

`voiceink-history mcp [--namespace …]` runs a Model Context Protocol server over
stdio. Configure a client with the absolute path of the built binary, for example:

```json
{
  "mcpServers": {
    "voiceink-history": {
      "command": "/path/to/VoiceInk/cli/parakeet/.build/release/voiceink-history",
      "args": ["mcp"]
    }
  }
}
```

Tools, all annotated `readOnlyHint`: `list_history(limit?, since?, until?,
cursor?)`, `search_history(query, limit?, since?, until?, cursor?)` and
`get_history_entry(id)`. Each returns the version 1 JSON above as text and as
`structuredContent`. When VoiceInk is not running or access is off, the tool
result is an error that says so; the server keeps running.

## Security and privacy

- The app owns a Unix domain socket in the per-user Darwin temporary directory
  (`getconf DARWIN_USER_TEMP_DIR`, mode 0700), named after the build's persistence
  directory, for example `com.prakashjoshipax.VoiceInk.history.sock`. The socket
  is mode 0600. The app accepts only peers with the same user ID, and the client
  refuses a path that is not a socket owned by the current user. There is no TCP
  listener; other machines and other macOS accounts cannot connect.
- Any program running under your account can read History while access is on.
  Leave it off when you do not use it.
- Requests are read-only: the app fetches from an isolated SwiftData context and
  never saves. Requests are limited to 16 KiB, 5-second I/O and four concurrent
  connections. Neither side logs queries or transcription text.
- Transcripts leave the Mac only through whatever transport your MCP client or
  terminal uses.
