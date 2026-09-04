# Plugin lifecycle payload corpus

Real `Plugin` aggregate event payloads, exactly as they were written to a deployed event log,
kept so that every one of them still decodes against the **current** `PluginSpec.eventSchema`.

Read by [`PluginLifecycleCorpusTest.res`](../../plugin/PluginLifecycleCorpusTest.res) through
[`PluginLifecycleCorpus.res`](../../plugin/PluginLifecycleCorpus.res).

## Never regenerate these files

They are frozen. A fixture rebuilt from today's ReScript types tests nothing — it tracks the schema
it is supposed to be pinning, which is exactly how the 2026-07-30 wedge got past the two
hand-constructed cases already in `MessageTest.res`.

**Adding** an entry is fine, and is what you do when a payload shape changes: take a real event from
a deployed log and append it. **Editing or re-encoding** an existing entry defeats the point.

## What each entry pins

| file | shape generation |
|---|---|
| `2026-07-22-versionconnected-no-requiredstores.json` | before `requiredStores` existed |
| `2026-07-22-versionsuperseded-nested-definitions.json` | the `VersionSuperseded` payload — two nested definitions, not one |
| `2026-07-28-versionconnected-requiredstores-only.json` | `requiredStores` present, `requiredStoreDeclarations` not yet |
| `2026-07-30-versionconnected-declarations-without-annotation.json` | declarations as `{store, component, field}` — the payload that froze the `Catalog` plugin when `annotation: string` was added as required |
| `2026-07-30-versiondisconnected-declarations-without-annotation.json` | same generation, the other variant the aggregate re-emits from stored state |

## Provenance

Recovered from the `Catalog` partition of a deployed `PluginAggrEventLog` table on 2026-08-01.
Each file is the decode-relevant part of the stored row — `{event, data}` — which is what
`EventLog_Operations.decodeEvent` reassembles via `Message.combineMessage` before decoding.

One transformation was applied at extraction: the AWS account id in embedded ARNs and queue URLs
was replaced with `000000000000`. The corpus asserts *shape*, and the shape of a string does not
depend on its contents.

A second was applied on 2026-09-04, when `pluginDefinition`'s optionals moved from `T | null` to
sury's default encoding, where an absent value is an omitted key. Null-valued keys were removed
from every entry — 18 to 36 per file — and nothing else was touched: the rewrite round-trips each
file through `JSON.parse`/`stringify` unchanged before it edits, and a key-by-key diff against the
previous revision reports null removals and no other difference. The two `Offload` fields keep
their nulls, their codec being unaffected.

This is the one edit the rule above permits, and only because it is not a regeneration: no fixture
was rebuilt from ReScript types, so every generation in the table is still the one it was captured
at, and each entry still pins exactly the absence it was kept for. What it stops pinning is the
encoding that was deleted — which no longer exists to be pinned.
