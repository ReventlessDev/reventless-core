# Plan: Support Payload-less Event Variants in Event Log Serialization

**Status: Done**

## Problem

ReScript variants without inline record payloads (e.g., `| Shipped`, `| Archived`, `| Deactivated`) fail round-trip serialization through the event log.

**Root cause**: `Message.splitMessage` expects a JSON **object** with a `TAG` field, but sury encodes payload-less variants as JSON **strings** (e.g., `"Shipped"` instead of `{TAG: "Shipped"}`).

## Fix Applied

Two functions updated in `reventless/reventless-core/src/Message.res`:

1. **`splitMessage`** — added a fallback branch for bare JSON strings (payload-less sury variants), extracting the variant name and returning an empty payload dict.

2. **`combineMessage`** — when the data dict is empty, returns `JSON.String(typ)` (bare string) instead of wrapping in `{TAG: ...}`, matching what sury expects for payload-less variants.

No changes needed to `EventLog_Operations.res` — it already handles `None` data correctly, and the updated `combineMessage` produces the right output.

## Verification

- All 85 test suites pass (698 tests), including MessageTest and EventLogOperationsTest
- Zero compiler warnings
- Guide updated: `docs/guides/platform-and-plugin-guide.md` now documents payload-less variants as fully supported
