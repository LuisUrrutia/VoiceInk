# Unindexed History fixture

`unindexed.store` is a closed, checkpointed synthetic SwiftData store for
`HistoryIndexTests`. It was generated in a separate process using the production
`Transcription` model at `8f7e3a2e2c868e76edb2817febf2056dc5a2f197`, before the
compound index and timestamp hash modifier. Generation used macOS 26.6.2,
Swift 6.4 and a macOS 15 deployment target. No user store or audio was used.

The fixture contains 65 records numbered 0–64. UUIDs use
`%08X-ABCD-4DEF-8123-%012X`, with the record number in both substitutions.
Timestamps are `1700000000 - floor(number / 23)` seconds since 1970, and
durations are `number + 0.5`. This puts timestamp ties across four History pages.

Even records have original `Café original <number>` text and nil optional
metadata. Odd records have `Other text <number>` and enhanced
`Enhanced café <number>` text, plus synthetic audio URLs, model/prompt names,
request messages, mode names/emoji and processing durations. Status cycles through
pending, completed, failed and canceled; every fifth status is nil.

The test copies the fixture before opening it, checks that it has no compound
index, then verifies physical index creation, every field, ordering, localized
matching and reopening. Keep the bundled fixture unmodified: generating it with
the current indexed model would remove the upgrade regression.

SHA-256: `95746f94b88b7c3a32d5c73e55ff6f6bd3125179c95334e9841a0b8a593a8b2e`.
