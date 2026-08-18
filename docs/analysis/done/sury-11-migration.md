# Sury 11 API Migration Analysis (11.0.0-alpha.4 → current)

> **Re-target update (2026-07-04), verified by a compile+run spike.** This
> analysis was first written to migrate `alpha.4 → alpha.5`. Sury is now
> **`11.0.0-alpha.8`** (current `latest`; the repo still pins `alpha.4`), which
> is the new target. An **isolated spike** — a throwaway ReScript package on
> `sury@11.0.0-alpha.8` + `sury-ppx@11.0.0-alpha.8`, built with `rescript@12.3.0`
> and *executed* — established the following (measured, not inferred):
>
> - ✅ **The one hard blocker is gone.** `sury-ppx@11.0.0-alpha.8` now exists and
>   compiles `@schema` types against `sury@alpha.8` (the analysis below still says
>   "no alpha.5 PPX release, latest alpha.2" — obsolete). A `@schema` variant
>   (record + payload-less arms) compiled and round-tripped through the wire.
> - ✅ **The ReScript API is essentially the alpha.5-corrected form.**
>   `parseOrThrow(~to=)` and `decodeOrThrow(value, ~from=, ~to=)` with **labeled**
>   args are present, and **`nullAsOption` is present** (opportunity A unchanged).
> - ⚠️ **Read `S.resi`, not the TypeScript `.d.ts`.** sury's `.d.ts` surface
>   *diverges* from its ReScript interface — the `.d.ts` drops `*OrThrow` /
>   `nullAsOption` and adds an `encoder`. This is a **ReScript** codebase, so
>   `S.resi` is authoritative. **There is no `S.encoder` in ReScript.** (An
>   earlier revision of this note trusted the `.d.ts` and was wrong on every
>   point above — corrected here from the spike.)
> - ✅ **Verified conversion idiom** (round-tripped at runtime):
>   `json->S.parseOrThrow(~to=schema)` (JSON→typed) and
>   `value->S.decodeOrThrow(~from=schema, ~to=S.json)` (typed→JSON, and
>   `~to=S.jsonStringWithSpace(n)` for a string). `S.toExpression` reported the
>   TAG shape `{ TAG: "Added"; … } | "Cleared"` — payload-less variants still
>   serialise as bare strings.
> - 📌 **Bidirectional transforms** (opportunity C / event versioning) use
>   `S.transform(schema, s => {parser, serializer})` — **not** `S.to(~decode,
>   ~encode)`. `S.to` is pure schema chaining `(from, to) => t<to>`.
> - 📌 **No `S.Exn` module** in the ReScript API — **opportunity D needs
>   re-scoping** to the actual error surface (`errorMessage` fields + thrown
>   `JsExn`) before it's actionable.
> - ➡️ **The removed alpha.4 API is unchanged through alpha.8** (`reverseConvert*`,
>   `parseJson*`, `convert*`, `enableJson`, …) — the sweep target is the same.
>
> The conceptual-model table, migration mapping, and `Util_Sury` shim below
> reflect this **spike-verified** ReScript API. The `S.t.Object` introspection
> change (`items` → `properties`, the `TAG` discriminant lookup) in the Phase 1
> findings still applies; re-confirm the exact introspection shape during the port.

**Implementation plans built on this analysis:**
- [`docs/plans/sury-11-migration.md`](../plans/sury-11-migration.md) — main
  migration sweep (Phases 0–5), folds in opportunities A, B, D, E, H.
- [`docs/plans/Backlog/sury-event-schema-versioning.md`](../plans/Backlog/sury-event-schema-versioning.md)
  — opportunity C, deferred.
- [`docs/plans/Backlog/typed-graphql-sdl-from-sury.md`](../plans/Backlog/typed-graphql-sdl-from-sury.md)
  — opportunity F, deferred; companion to `Backlog/api-component-openapi.md`.
- [`docs/plans/Backlog/typescript-client-sdk.md`](../plans/Backlog/typescript-client-sdk.md)
  — opportunity G, deferred.

**Context**: Lambda Layer `reventless-aws-alpha:58` shipped with `sury@11.0.0-alpha.5`
(npm re-resolved `^11.0.0-alpha.4` upward because the Layer builder downloads from
the registry and does not honour the workspace `pnpm-lock.yaml`). The heartbeat
Lambda — and any other Lambda whose code imports a removed sury export — now
crashes at init with:

```
SyntaxError: The requested module 'sury/src/S.res.mjs' does not provide an
export named 'reverseConvertToJsonOrThrow'
```

Local builds keep working because `node_modules/sury@11.0.0-alpha.4` is still
pinned by the lockfile. The bug is invisible in dev/test and only surfaces in
deployed Lambdas built through the Layer pipeline.

Pinning `sury` to `11.0.0-alpha.4` would unblock today's deploy but freezes the
framework on a now-superseded prerelease. This document analyses the migration
to the new API so the pin is replaced with code that works on alpha.5+.

## Conceptual model change

Sury 11 replaces the alpha.4 `convert`/`reverseConvert`/`parseJson` family with
`parseOrThrow` / `decodeOrThrow` (labeled `~to` / `~from`), plus builder forms
(`parser` / `decoder`) that return reusable closures. The mental model (all
rows **spike-verified** against `sury@11.0.0-alpha.8`'s `S.resi`):

| alpha.4 API                    | sury 11 (alpha.8, ReScript)                                       | Direction              |
| ------------------------------ | ----------------------------------------------------------------- | ---------------------- |
| `parse*` / `parseJson*`        | `value->S.parseOrThrow(~to=schema)`                               | `unknown/JSON → Output` |
| `convert*` (typed in)          | `value->S.decodeOrThrow(~from=srcSchema, ~to=schema)`             | `Input → Output`       |
| `reverseConvertToJson*` (encode) | `value->S.decodeOrThrow(~from=schema, ~to=S.json)`               | `Output → JSON`        |
| `reverseConvertToJsonString*`  | `value->S.decodeOrThrow(~from=schema, ~to=S.jsonStringWithSpace(n))` | `Output → string`   |
| `parseJsonString*`             | `str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)`           | `string → Output`      |
| `enableJson()` / `enableJsonString()` | (removed — JSON schemas are always active)                 | n/a                    |

Notes (from the spike):
- **There is no `S.encoder` in the ReScript API** (it exists only in the TS
  `.d.ts`). Encoding is `decodeOrThrow(value, ~from=schema, ~to=S.json)` — the
  `~from=schema` end supplies the typed value; no `S.reverse` gymnastics needed.
- For **hot paths** (opportunity B), build a reusable closure once with
  `S.parser(~to=schema)` / `S.decoder(~from=…, ~to=…)` instead of the one-shot
  `*OrThrow` calls.
- `S.reverse: t<'value> => t<unknown>` still exists for hand-rolled reversal, but
  the encode idiom above doesn't need it.

## What was removed (vs. alpha.4)

Diffed from the exports of `node_modules/sury@11.0.0-alpha.4/src/S.res.mjs`
against `sury@11.0.0-alpha.8` (originally captured against the `alpha.5` bundle
in Layer 58; the removed set is unchanged through alpha.8):

**Removed:**
- `convertOrThrow`, `convertAsyncOrThrow`, `convertToJsonOrThrow`, `convertToJsonStringOrThrow`
- `reverseConvertOrThrow`, `reverseConvertToJsonOrThrow`, `reverseConvertToJsonStringOrThrow`
- `parseJsonOrThrow`, `parseJsonStringOrThrow`
- `enableJson`, `enableJsonString`
- `compile`, `unnest`, `datetime`
- Type aliases: `$$Array`, `$$String`, `Float`, `Int`, `ErrorClass`

**Structural changes to `S.t` introspection (discovered Phase 1):**
- `S.t.Object` no longer has the `items: array<{name, location, schema}>`
  record. Only `properties: dict<t<unknown>>` (plus `additionalItems`,
  `required`, etc.) remains. The alpha.4 `items` array carried per-field
  `location` metadata distinguishing the variant `"TAG"` discriminant from
  payload fields; in alpha.5 the `TAG` discriminant simply appears in
  `properties` under the literal key `"TAG"` with a `String({const: …})`
  schema.
- `S.t.Array` retains its own `items: array<t<unknown>>`. The two `items`
  fields are not the same thing — the alpha.4 `Object.items` was metadata,
  the alpha.5 `Array.items` is the element-schema list.
- Affected callers in this repo: `reventless-spec/src/components/DcbDecode.res`
  and `DcbTag.res` walk variant schemas using
  `Object({items}).find(item => item.location == "TAG")`. That has to be
  rewritten as `Object({properties}).Dict.get("TAG")`.

**Added in sury 11 (present in alpha.8's ReScript `S.resi`, spike-confirmed):**
- `parseOrThrow` / `parseAsyncOrThrow` (`(value, ~to)`), `decodeOrThrow` /
  `decodeAsyncOrThrow` (`(value, ~from, ~to)`), `assertOrThrow` / `assertAsyncOrThrow`
- `parser` / `asyncParser` (`~to`) and `decoder` / `asyncDecoder` (`~from`, `~to`) —
  builders returning reusable closures; plus `decoder1: t<'value> => unknown => 'value`
- `transform` (`(schema, s => {parser?, serializer?})` — the bidirectional primitive),
  `to: (t<'from>, t<'to>) => t<'to>` (pure schema chaining)
- `nan`, `date`, `isoDateTime`, `nullable`, `nullAsOption`, `compactColumns`
- `json`, `jsonString`, `jsonStringWithSpace`, `reverse`, `toExpression`,
  `toJSONSchema` / `fromJSONSchema` / `extendJSONSchema`

**TypeScript-vs-ReScript surface divergence (important).** sury's `.d.ts` (TS
consumers) and its `.resi` (ReScript consumers) are **not the same API**. The
`.d.ts` drops `*OrThrow` and `nullAsOption` and adds an `encoder`; the ReScript
`.resi` keeps `*OrThrow`/`nullAsOption` and has **no `encoder`**. This is a
ReScript codebase → `S.resi` is authoritative. (An earlier revision of this
analysis mistakenly used the `.d.ts`; the spike corrected it.) Net effect for
this migration: **the alpha.5-corrected mapping — labeled `~from`/`~to`,
`decodeOrThrow`/`parseOrThrow`, `nullAsOption` — is exactly right for alpha.8**;
opportunities B, E, F, G hold; A stays as `S.nullAsOption`; C uses `S.transform`;
D (`S.Exn`) has no ReScript module and needs re-scoping.

## Codebase impact

`grep -rn "S\.<api>" --include="*.res"` across the workspace (excluding
`node_modules`, `/lib/`, and `/builder/layer/`):

| Old API                              | Call sites (`.res`) | Notes                                        |
| ------------------------------------ | ------------------- | -------------------------------------------- |
| `S.reverseConvertToJsonOrThrow`      | ~95                 | Largest fan-out; encode typed → JSON         |
| `S.parseJsonOrThrow`                 | ~36                 | JSON → typed; mostly in test fixtures        |
| `S.enableJson()`                     | ~41                 | Pure deletion — no-op in alpha.5             |
| `S.convertOrThrow`                   | 3                   | In-memory Platform: JSON → typed             |
| `S.parseJsonStringOrThrow`           | 2                   | One in `rescript-pulumi-aws` policy parsing  |
| `S.reverseConvertToJsonStringOrThrow`| 2                   | `reventless-codegen` exporters               |

Packages affected (file count):

| Package                  | Affected `.res` files |
| ------------------------ | --------------------- |
| `reventless-core`        | 29                    |
| `reventless-local`   | 22                    |
| `reventless-gwt`         | 10                    |
| `reventless-codegen`     | 6                     |
| `reventless-spec`        | 4                     |
| `reventless-interop`     | 2                     |
| `reventless-aws`         | 2                     |
| `rescript-pulumi-aws`    | 1                     |
| **Total**                | **76 files**          |

Plus one hand-written `.mjs`:
- `reventless/aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs` imports
  `reverseConvertToJsonOrThrow` directly. This is the file currently crashing
  on Layer 58.

**Not affected:**
- `sury-ppx` — no alpha.5 release exists (latest is `11.0.0-alpha.2`). The PPX
  does not emit calls to the removed runtime APIs at code-gen time.
- Generated `.res.mjs` outputs — they regenerate from `.res` sources, so once
  the sources are migrated the outputs follow.

## Migration mapping

The cardinality is small enough for a `find + sed`-driven rewrite for the easy
cases, with manual review of the 5 remaining call shapes:

```text
# 1.   S.enableJson()                           (~41 calls)
       → delete the line
# 2.   x->S.parseJsonOrThrow(schema)            (~36 calls)
       → x->Util_Sury.fromJson(schema)          (= x->S.parseOrThrow(~to=schema))
# 3.   value->S.reverseConvertToJsonOrThrow(s)  (~95 calls)
       → value->Util_Sury.toJson(s)             (= value->S.decodeOrThrow(~from=s, ~to=S.json))
# 4.   v->S.reverseConvertToJsonStringOrThrow(s, ~space=2)
       → v->Util_Sury.toJsonString(s, ~space=2) (= v->S.decodeOrThrow(~from=s, ~to=S.jsonStringWithSpace(2)))
# 5.   str->S.parseJsonStringOrThrow(schema)
       → str->Util_Sury.fromJsonString(schema)  (= str->S.decodeOrThrow(~from=S.jsonString, ~to=schema))
# 6.   json->S.convertOrThrow(schema)           (3 in-memory calls)
       → json->Util_Sury.fromJson(schema)       (JSON is unknown → S.parseOrThrow(~to=schema))
```

**Encode direction (#3/#4)** — encoding (typed → JSON) is
`value->S.decodeOrThrow(~from=schema, ~to=S.json)`: the `~from=schema` end
supplies the typed value and sury serialises it to the `~to` target. There is no
`S.encoder` in the ReScript API, and no `S.reverse` is needed here. For hot
serialisation paths (message envelopes, event log writes), hoist a reusable
closure with `S.decoder(~from=schema, ~to=S.json)` once per spec (opportunity B);
cold paths can use the one-shot `decodeOrThrow`.

A pragmatic call: keep every call site behind a tiny helper so the sury-11
vocabulary is isolated in one place. The shim lives in
`reventless-spec/src/util/Util_Sury.res` (not `reventless-core/src/util/` as
the first draft suggested — `reventless-spec` itself has 4 sury-using files
and is the lowest framework package using sury, so the shim has to sit there):

```rescript
// reventless-spec/src/util/Util_Sury.res  (alpha.8 — spike-verified, round-trips)
let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
  value->S.decodeOrThrow(~from=schema, ~to=S.json)                        // typed → JSON
let toJsonString: ('a, S.t<'a>, ~space: int) => string = (value, schema, ~space) =>
  value->S.decodeOrThrow(~from=schema, ~to=S.jsonStringWithSpace(space))  // typed → string
let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) =>
  json->S.parseOrThrow(~to=schema)                                        // JSON → typed
let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
  str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)                    // string → typed
```

These four exactly match a probe that compiled on `sury@alpha.8` + `sury-ppx@alpha.8`
and round-tripped a `@schema` variant (record + payload-less), a record with an
`option`, and the JSON-string form. That keeps the diff per call site to a
near-mechanical s/old/new and makes a future **sury 12** migration a one-file
change. Inside `reventless-spec` the shim is `Util_Sury`; from other packages it
is `Reventless.Util_Sury` (`reventless-spec` declares `namespace: "Reventless"`).

## Phase 1 investigation findings (2026-05-17)

Captured from the `sury-alpha5-phase1` branch experiment (snapshot commit
`bb689a73e`). The branch bumped sury to alpha.5 across all 9 framework +
adapter packages locally, dropped the `Util_Sury` shim into
`reventless-spec/src/util/`, and ran `pnpm exec rescript build` from
`reventless-spec`. Three things were learned **before any source-side port
happened**:

> **Confirmed still valid for alpha.8 (by the 2026-07-04 spike).** Finding #1's
> labeled-arg signatures for `parseOrThrow` / `decodeOrThrow` are unchanged in
> alpha.8's `S.resi` — the shim and mapping above use exactly this form. All four
> findings apply as written.

1. **Shim API signatures in the original analysis were wrong.** The plan and
   the migration-mapping table both showed `decodeOrThrow(value, from, to)`
   and `parseOrThrow(value, schema)` with positional arguments. The real
   signatures (`S.resi:394–405`, unchanged in alpha.8) use labeled args:
   `parseOrThrow: ('any, ~to: t<'value>) => 'value`,
   `decodeOrThrow: ('from, ~from: t<'from>, ~to: t<'to>) => 'to`. *(The 2026-07-04
   spike confirmed both compile and round-trip on alpha.8.)*

2. **`S.t.Object` lost its introspection `items` field.** Already captured in
   "Structural changes to `S.t` introspection" above. The two callers
   (`DcbDecode.res`, `DcbTag.res`) need to switch from
   `items.find(item => item.location == "TAG")` to `properties.get("TAG")`.
   This is a real plan-relevant change: it adds a fifth call-site shape that
   the bulk `sed` sweep can't handle by itself.

3. **Phase-1 file scope was undercounted.** The plan said "port two pivotal
   files (`Message.res` + `Projection.res`)" and run the test suites. With
   sury bumped to alpha.5, `reventless-spec` won't build until its 4
   sury-using files (`types/Message.res`, `types/Identity.res`,
   `types/StoredEvent.res`, `components/DcbDecode.res` + the schema
   introspection in `components/DcbTag.res`) are also ported. `reventless-core`
   has ~29 affected files; `reventless-local` has ~22. The "two pivot
   files" framing is preserved in the revised plan as the **careful manual
   port**, but the build forces ~55 files of collateral that get done in the
   same phase. Phase 2's scope shrinks correspondingly (see plan revision).

4. **Util_Sury location.** Plan said `reventless-core/src/util/`; correct
   placement is `reventless-spec/src/util/` (lowest dep using sury). Above
   in this doc the helper-block has been corrected.

Open questions still outstanding after these findings:

## Open questions / risks

1. **Behavioural equivalence**: Did `reverseConvertToJsonOrThrow` in alpha.4
   apply any transforms that `S.reverse(s)` + `S.json` in alpha.5 won't?
   Specifically: how does each handle schema-level refinements, `S.transform`,
   `S.refine`, and `@s.matches` (sury-ppx)? Needs a focused test pass on
   `Message.res` (event/command envelope encoding) and `Projection.res` (state
   serialisation) before bulk-migrating.

2. **Error type/shape**: the alpha.5 `Exn` module is **gone in alpha.8** —
   there's an `Error` const + `code` union types instead. Any code that
   pattern-matches on sury errors (look for `S.error`, `S.$$Error`, `JsExn`
   against sury) needs review against the alpha.8 error surface, and
   **opportunity D must be re-scoped** to whatever alpha.8 actually exposes
   before it's actionable. None spotted in the initial grep but worth a second
   pass.

3. **sury-ppx ↔ sury version match**: **resolved** — `sury-ppx@11.0.0-alpha.8`
   now exists (the original blocker was "no alpha.5 PPX release, latest
   alpha.2"). Bump the ppx to `alpha.8` alongside sury so there's no skew; the
   PPX emits `S.schema(s => …)` and `s.m(…)`, both still present in alpha.8.
   Still warrants compiling a single PPX-using package against
   `sury@alpha.8 + sury-ppx@alpha.8` before committing to the migration.

4. **Other consumers of removed APIs in transitive deps**: a Layer-builder
   re-resolve might also pull a new version of `rescript-relay` or similar
   that uses the alpha.4 API. Worth grepping the built Layer zip's `node_modules`
   for `reverseConvertToJsonOrThrow` usages from non-Reventless packages.

5. **`enableJson()` removal**: deleting the calls is mechanical, but if the
   function did more than gate tree-shaking (e.g. registered a global) we
   could lose behaviour silently. Confirmed via reading alpha.4's source: it
   only swapped in a non-tree-shaken schema definition. Safe to delete.

## Recommended approach

**Phase 0 — unblock production**: ship the sury pin (`"sury": "11.0.0-alpha.4"`
exact, no caret, in `reventless-{aws,core,infra,spec}/package.json`) as a
hotfix on `alpha`. Restores deploys today; no behaviour change.

**Phase 1 — central helper + smoke test**: add `Util_Sury` with `toJson` /
`fromJson` / `toJsonString` / `fromJsonString` shims, switch `Message.res` +
`Projection.res` to use them. With both packages bumped to sury alpha.8
locally (and `sury-ppx@alpha.8`) and the helper in place, run the full
`reventless-core` and `reventless-local` test suites. This validates (a) the
encoder-direction equivalence question and (b) `sury-ppx@alpha.8` + `sury@alpha.8`
compatibility on a small surface.

**Phase 2 — bulk migration**: scripted s/old/new over the 76 affected `.res`
files plus `HeartbeatEntryPoint.mjs`. Each replaced call uses the
`Util_Sury` helper, not the raw `S.decodeOrThrow(…)` / `S.parseOrThrow(…)` form,
so the diff is uniform.

**Phase 3 — remove the pin + ship**: delete the `^11.0.0-alpha.4` pin (or
bump to `11.0.0-alpha.8`) and let CI publish a new Layer. The pin
removal **and** Layer re-publish must happen in the same release window —
otherwise a Layer build between Phase 1's merge and Phase 3's release would
re-introduce the version split.

**Phase 4 — delete `Util_Sury` (optional)**: if the helper turns out to add
nothing over inlining, fold it back. Most likely worth keeping as a sury-version
isolation seam.

## Validation plan

- All existing framework tests must pass on alpha.8 with no skip/xfail
  additions (the suite has grown since this doc's original 802 = 386 core +
  416 in-memory baseline).
- Add 1-2 round-trip property tests: random typed state → encode → decode →
  equal-to-input. Cover at least one variant-with-payload event spec and one
  record state spec.
- After deploy: invoke `CatalogPluginHeartbeat-*` directly, assert the EP
  dispatcher logs show `EP→Plugin: Heartbeat(Catalog@…)` followed by a
  successful `applyCommandAction` (no "Aggregate Plugin doesn't exist").
- Query `Platform_Plugins`: should return ≥ 1 edge with non-null `name`,
  `version`, `status` after the first post-deploy heartbeat.

## Opportunities the sury 11 upgrade unlocks

The migration is not just a like-for-like API swap — sury 11 closes several
gaps that prior analyses called out as missing or worked around. Listed in
rough order of how directly they pay off, with cross-references to existing
analysis/plan documents.

### A. Replace the `js_nullable` workaround (direct fix)

**What's new:** sury 11 handles `T | null → option<T>` without admitting
`undefined` into the union. **Note:** the alpha.5 export named for this
(`S.nullAsOption`) is **gone in alpha.8** — use `S.nullable` / `S.nullish`
instead (confirm which yields the `T | null` (no `undefined`) shape the union
payloads need, in Phase 1).

**Pain it removes:** the codebase currently imports `js_nullable` from sury's
internal `Sury.res.mjs` to dodge a known bug in `S.nullableAsOption` documented
in CLAUDE.md memory and `docs/plans/done/api-component-graphql.md` "Critical
issue: sury `jsonableValidation` rejects `S.option(T)` inside union variant
payloads". The workaround:

```rescript
@module("sury/src/Sury.res.mjs")
external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"
let myOptionSchema = _jsNullable(baseSchema, ())
```

becomes, on alpha.8:

```rescript
let myOptionSchema = baseSchema->S.nullAsOption   // present in S.resi (spike-confirmed)
```

Search target for the fix: every site importing `js_nullable` from
`sury/src/Sury.res.mjs` (currently used to make `apiSchemaFragment` survive
`jsonableValidation` in union variants).

### B. Hoisted parser / decoder closures for hot paths

**What's new:** `S.parser(~to=schema): 'any => 'value` and
`S.decoder(~from, ~to): 'from => 'to` return reusable closures, instead of
recomputing the parser on every call as `parseJsonOrThrow` did.

**Pain it removes:** Every event log replay, every projection update, every
Lambda command handler currently calls `S.parseJsonOrThrow(schema)` inline,
which means sury re-derives the parser on each invocation. With `parser`, the
closure is cached at module init.

```rescript
// alpha.4 hot path — re-builds parser per event
let event = json->S.parseJsonOrThrow(Spec.eventSchema)

// alpha.8 — build once, call many
let parseEvent = S.parser(~to=Spec.eventSchema)
let event = parseEvent(json)
```

This is the most material runtime win: the Lambda cold/warm cycle does the
parser-construction work exactly once per spec, rather than per event. Likely
candidates to hoist first: `Message.res` (envelope decode/encode), `Projection.res`
(state load/save), and the EventLog operations.

### C. Native event schema versioning via `S.transform`

**What's new (corrected from the spike):** the bidirectional transform primitive
in alpha.8's ReScript API is `S.transform(schema, s => {parser?, serializer?})`
(from `S.resi` — `parser` is decode old→new, `serializer` is encode new→old).
`S.to: (t<'from>, t<'to>) => t<'to>` is **pure schema chaining** (no transform
functions) and `S.decoder` threads a value through a schema chain. Together these
give the bidirectional migration the `Effect.Schema.transform` pattern in
`docs/plans/done/effect-library-integration.md` Tier 3 §10 wanted. *(Both the
original `S.to(schema, ~decode, ~encode)` and a later `positional` draft of this
line were wrong — the primitive is `S.transform`.)*

**Pain it removes:** That doc lists "no schema versioning" as a tier-3 gap, and
`docs/analysis/event-format-and-meta-review.md` calls out the wishlist item
"Free `dataschema` slot for sury / version migrations" — the underlying need
was bidirectional event migration on replay.

```rescript
// A v1-shaped stored event decodes into the current `event` type via a transform
let eventFromV1 =
  v1Schema->S.transform(_ => {
    parser: (v1: V1.event) => migrate(v1),      // decode: old → new
    serializer: (e: event) => downgrade(e),     // encode: new → old
  })
```

Replay can then read both v1 and v2 records into a single typed view, removing
the current "rename a field and break replay" foot-gun without needing the
heavier Effect Schema migration discussed in `done/effect-library-integration.md`.

**Plan:** [`docs/plans/Backlog/sury-event-schema-versioning.md`](../plans/Backlog/sury-event-schema-versioning.md).

### D. Structured sury errors

> **Re-scope for alpha.8:** the `S.Exn` module this opportunity was written
> against **does not exist in alpha.8** — the error surface is an `Error` const
> plus `code` union types instead. The pain below is still real; the mechanism
> must be re-derived from alpha.8's actual error API before this is actionable.

**What was proposed (alpha.5):** `S.Exn` exposes a typed error type with the
failure path, expected schema, and received value already split out (instead of
a stringly-typed `JsExn.message`).

**Pain it removes:** Current code catches `JsExn` and grabs `.message` for
logging. There's no programmatic access to "which field failed" or "what
schema rejected it". `docs/analysis/given-when-then-specifications.md` notes
that Jest's structural diff is opaque for sury-produced mismatches — the GWT
layer renders custom diffs. With `S.Exn` the framework can render the same
information consistently in production logs and dev tooling.

### E. `isoDateTime` and `date` primitives

**What's new:** `S.isoDateTime: Schema<string, string>` (validated ISO 8601)
and `S.date: Schema<Date, Date>` (typed Date object).

**Pain it removes:** `Message.meta.time` is currently a free-form `string`,
constructed via `Message.nowAsISOString()`. Tests like
`docs/analysis/event-format-and-meta-review.md` describe `time` as "ISO 8601
string" by convention, not by validation. Switching `time` (and
`statusChange.at` on `PluginReadModelSpec`, etc.) to `S.isoDateTime` enforces
that at the type-and-validation level and emits stricter JSON Schema output.

### F. `S.toJSONSchema` → OpenAPI / GraphQL SDL generation (unblocks two backlog items)

**Still available, now worth revisiting.** alpha.5 keeps `S.toJSONSchema`,
`S.fromJSONSchema`, and `S.extendJSONSchema` — the same set as alpha.4. The
exit from `docs/analysis/rejected/sury-vs-effect-schema.md` was:

> The path to type-driven GraphQL SDL in Reventless runs through sury's
> existing JSON Schema output, not through a library swap.

and the active backlog plan `docs/plans/Backlog/api-component-openapi.md`
already plans an OpenAPI provider that needs the same primitive. The alpha.5
migration is a low-overhead moment to also:

- Replace the hand-written SDL templates in
  `QueryDbResolvers_GraphQL.res` and `CommandGeneratorResolvers_GraphQL.res`
  with `S.toJSONSchema → GraphQL SDL` derivation, giving strongly-typed
  resolver return types instead of opaque `String` / `JSON` scalars (the
  problem §3.1 of the rejected doc identifies).
- Provide the JSON-Schema-shaped fragment that the OpenAPI backlog plan
  expects under `schemaFragment.encoded`.

Both pay off once: the converter is one module and serves both providers.

**Plan:** [`docs/plans/Backlog/typed-graphql-sdl-from-sury.md`](../plans/Backlog/typed-graphql-sdl-from-sury.md)
(companion to the existing
[`docs/plans/Backlog/api-component-openapi.md`](../plans/Backlog/api-component-openapi.md)).

### G. Standard Schema v1 → TypeScript client without sury-ppx

**Already in alpha.4, still in alpha.5.** sury implements Standard Schema v1
(`"~standard"` properties). `docs/analysis/typescript-client-feasibility.md`
Blocker 1 was "sury-ppx doesn't exist for TypeScript so TS callers must hand-
write sury schemas". Standard Schema is the official escape hatch:

- TS callers write schemas in **zod** or **valibot** (or any of the 19+ Standard
  Schema providers listed in the sury README).
- A thin Reventless TS SDK uses the `"~standard"` interface to validate inputs
  and read DCB-tag metadata from the same schema, without needing to know
  whether the underlying library is sury, zod, or valibot.

This makes the "Option B — zod/valibot bridge" path the typescript-client doc
sketches into a much smaller piece of work than implied: no custom bridge,
just consuming Standard Schema interfaces.

**Plan:** [`docs/plans/Backlog/typescript-client-sdk.md`](../plans/Backlog/typescript-client-sdk.md).

### H. Removal of `enableJson()` ceremony

**What changes:** `S.enableJson()` and `S.enableJsonString()` are gone in
alpha.5 — JSON-handling schemas are always active.

**Pain it removes:** 41 call sites of `S.enableJson()` exist purely to
unlock the JSON schema before use in tests and GWT fixtures. They become
deletable noise. Small win, but real.

### Summary table

| Opportunity                                  | Existing doc                                                                            | Plan                                                                                | Effort         | Payoff |
| -------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------- | ------ |
| A. `nullAsOption` replaces `js_nullable`     | CLAUDE.md memory; `done/api-component-graphql.md`                                       | `sury-11-migration.md` Phase 2.3                                                | trivial        | direct |
| B. Hoisted `parser` / `decoder` / `encoder`  | (perf observation)                                                                      | `sury-11-migration.md` Phase 3                                                  | small per spec | Lambda perf |
| C. Schema versioning via `S.decoder` / `S.to` chains | `done/effect-library-integration.md` §10; `event-format-and-meta-review.md` #9   | `Backlog/sury-event-schema-versioning.md`                                           | medium         | unblocks event evolution |
| D. Structured sury errors (re-scope vs alpha.8) | `given-when-then-specifications.md` §"opaque diff"                                   | `sury-11-migration.md` Phase 2.4                                                | small          | observability |
| E. `isoDateTime` / `date`                    | `event-format-and-meta-review.md`                                                       | `sury-11-migration.md` Phase 2.5                                                | small          | tighter schemas |
| F. `toJSONSchema` → SDL / OpenAPI            | `rejected/sury-vs-effect-schema.md` §6.1; `Backlog/api-component-openapi.md`            | `Backlog/typed-graphql-sdl-from-sury.md`                                            | medium         | typed APIs |
| G. Standard Schema v1 TS interop             | `typescript-client-feasibility.md` Blocker 1; `done/effect-library-integration.md` §10  | `Backlog/typescript-client-sdk.md`                                                  | small SDK      | TS clients |
| H. Drop `enableJson()` calls                 | (cleanup)                                                                               | `sury-11-migration.md` Phase 2.1                                                | trivial        | clarity |

A, B, D, E, H land in the main migration plan (in-window cleanups). C, F, and
G are follow-on projects in their own backlog plans — the sury 11 migration
makes them materially easier without being prerequisites.

## References

- Sury repo: <https://github.com/DZakh/sury>
- Standard Schema spec: <https://standardschema.dev/>
- Current type definitions: `sury@11.0.0-alpha.8` `package/src/S.d.ts`
  (`npm view sury dist-tags` for the current `latest`; extract via
  `npm pack sury@<ver>`). The alpha.8 API surface referenced in the re-target
  note was read from this file.
- Inline-Lambda crash that triggered this:
  `reventless/aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs:5`
- Plans built on this analysis:
  - `docs/plans/sury-11-migration.md` — main migration sweep
    (Phases 0–5), covers opportunities A, B, D, E, H.
  - `docs/plans/Backlog/sury-event-schema-versioning.md` — opportunity C.
  - `docs/plans/Backlog/typed-graphql-sdl-from-sury.md` — opportunity F.
  - `docs/plans/Backlog/typescript-client-sdk.md` — opportunity G.
- Related analyses:
  - `docs/analysis/rejected/sury-vs-effect-schema.md` — verdict that the right
    path is "improve sury usage", not switch libraries.
  - `docs/analysis/typescript-client-feasibility.md` — TS client blockers.
  - `docs/analysis/event-format-and-meta-review.md` — event versioning wishlist.
  - `docs/plans/done/effect-library-integration.md` §10 — schema versioning gap.
  - `docs/plans/done/api-component-graphql.md` — `jsonableValidation` workaround.
  - `docs/plans/Backlog/api-component-openapi.md` — pending OpenAPI provider.
