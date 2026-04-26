# Mixed-source ReadModel — Phase 1 Audit

This is the audit deliverable for Plan 03 (`docs/plans/mixed-source-readmodel.md`),
Phase 1. It walks an event from a DCB StateChangeSlice through the runtime to a
hypothetical `ReadModel` callback and reports where the trace breaks.

## Trace summary

| Step | Code | Verdict |
|------|------|---------|
| 1. DCB topic merged into `allEventTopics` | [Plugin_Builder.res:246–252](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L246-L252), [Platform_Admin.res:171–175](../../reventless/reventless-core/src/admin/Platform_Admin.res#L171-L175) | ✅ Dict key = `name ++ "DcbEventLog"` |
| 2. `EventCollector` subscribes via `EventTopic.filter` | [ReadModel_Builder.res:79](../../reventless/reventless-core/src/components/ReadModel/ReadModel_Builder.res#L79) | ✅ Uses `Mapping.sourceName` to look up the dict key |
| 3. DCB events published with `meta.service` | [DcbEventLog_Operations.res:18](../../reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res#L18) | ❌ Sets `service = name` (plain plugin name) |
| 4. `MapperNto1.findMappings` filters by `meta.service` | [MapperNto1.res:57–63](../../reventless/reventless-core/src/MapperNto1.res#L57-L63), [ReadModel_Callback.res:23–24](../../reventless/reventless-core/src/components/ReadModel/ReadModel_Callback.res#L23-L24) | ✅ Compares `Mapping.sourceName == context.meta.service` |
| 5. `ReadModel_Builder.Make` accepts merged dict | [ReadModel_Builder.res:36](../../reventless/reventless-core/src/components/ReadModel/ReadModel_Builder.res#L36) | ✅ No signature change needed |

## The gap

Plan 03 §"Already implemented" point 2 claims: *"Events from the DCB log carry the
right `service` name … This matches the dict key from step 1 by construction."*

It doesn't. The dict key is `${pluginName}DcbEventLog` (e.g. `"CatalogDcbEventLog"`).
The `meta.service` field is `${pluginName}` (e.g. `"Catalog"`).

For a `Mapping.Make` whose `Source.name = "CatalogDcbEventLog"`:
1. `EventTopic.filter(["CatalogDcbEventLog"])` finds the topic in `allEventTopics`.
2. `EventCollector` subscribes to that topic; events arrive at `ReadModel_Callback`.
3. `context.meta.service = "Catalog"` (set by `DcbEventLog_Operations`).
4. `MapperNto1.findMappings` filters `"CatalogDcbEventLog" != "Catalog"` → empty.
5. **Silent no-op** — projection never runs.

## Why nobody hit this yet

A search of the codebase shows zero `Mapping.Make` calls with a DCB-source first
argument. Every `Mapping.Make` today consumes Aggregate events. The other DCB
consumers (`StateViewSlice`, `AutomationSlice`, `OutboundTranslationSlice`) bypass
`Mapping.sourceName` entirely — they decode events via `DcbDecode.makeDecoder`
and never read `meta.service`. So the broken path has been latent.

The Aggregate path works because `Aggregate_Callback.updateMeta` carries forward
`command'.meta.service` (set to `Spec.name` by `CommandPublisher`), which equals
the dict key in `Aggregate.allEventTopics` (also `Spec.name`).

## Resolution

A new **Phase 1.5** is added to Plan 03 to thread the dict-key-matching service
name through `DcbEventLog_Builder` → `DcbEventLog_Operations`. The cleanest fix:
add a `serviceName` field to the `DcbEventLog_Operations.Ops` module type and
have `DcbEventLog_Builder` populate it as `name ++ "DcbEventLog"`. Both
`Message.generateMeta(~service=…)` and the EventTopic publishJson call use that
value.

Without this fix, Phase 4's E2E test would fail (silent no-op) and Phase 5's
hybrid example would silently drop DCB events. Phase 2's typo fail-fast does not
catch the gap because the topic *is* present in `allEventTopics` — only the
per-event dispatch silently fails.
