# Sury 11.0.0-alpha.4 → 11.0.0-alpha.5 Migration Analysis

**Implementation plans built on this analysis:**
- [`docs/plans/sury-alpha5-migration.md`](../plans/sury-alpha5-migration.md) — main
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

Sury 11 split a single "convert" family into three distinct directions and a
schema-reversal primitive. The mental model:

| alpha.4 vocabulary             | alpha.5 vocabulary                                                                                            | Direction                   |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- | --------------------------- |
| `parse*`                       | `parser(~to)` / `parseOrThrow(value, ~to)`                                                                    | `unknown → Output`          |
| `convert*` (forward)           | `decoder(~from, ~to)` / `decodeOrThrow(value, ~from, ~to)`                                                    | `Input → Output` (typed in) |
| `reverseConvert*` (backward)   | `decodeOrThrow(value, ~from=schema->S.reverse, ~to=…)` — there is no inline `encoderOrThrow`                  | `Output → Input`            |
| `parseJson*`                   | `parseOrThrow(value, ~to=target)` (json IS unknown) **or** `decodeOrThrow(value, ~from=S.json, ~to=target)`   | `JSON → Output`             |
| `parseJsonString*`             | `decodeOrThrow(str, ~from=S.jsonString, ~to=target)`                                                          | `string → Output`           |
| `reverseConvertToJsonString*`  | `decodeOrThrow(value, ~from=S.reverse(schema), ~to=S.jsonStringWithSpace(n))`                                 | `Output → string`           |
| `enableJson()` / `enableJsonString()` | (removed — JSON schema is always active in alpha.5)                                                    | n/a                         |

`S.reverse(schema)` returns a new schema with `Input` and `Output` swapped, so
the encoding direction is expressed as "decode through the reversed schema".

> **Signature note** — `parseOrThrow`, `decodeOrThrow`, `parser`, and `decoder`
> all take the destination schema as a **labeled** `~to` argument in alpha.5,
> and `decodeOrThrow` / `decoder` take the source schema as **labeled**
> `~from`. The earlier draft of this analysis (and the migration mapping
> further down) showed positional arguments — that was wrong; corrected
> during the Phase 1 investigation. See `Sury.resi:394–405` in
> `node_modules/sury@11.0.0-alpha.5`.

## What was removed in alpha.5

Diffed from the exports of `node_modules/sury@11.0.0-alpha.4/src/S.res.mjs`
against the bundled `sury@11.0.0-alpha.5` inside Layer 58:

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

**Added:**
- `parser`, `asyncParser` — builders returning a parse function
- `decoder`, `asyncDecoder`, `decodeOrThrow`, `decodeAsyncOrThrow` — decode (typed in)
- `assertAsyncOrThrow`
- `nan`, `date`, `isoDateTime`, `nullAsOption`, `compactColumns`
- `Exn` module

`S.encoder` exists in `S.d.ts` but is **not re-exported through the OrThrow
runtime helpers** — callers either invoke the encoder closure
(`S.encoder(schema)(value)`) or go through `decodeOrThrow(value, S.reverse(schema), …)`.

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
- `reventless/reventless-aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs` imports
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
       → x->S.parseOrThrow(~to=schema)
# 3.   value->S.reverseConvertToJsonOrThrow(s)  (~95 calls)
       → value->S.decodeOrThrow(~from=s->S.reverse, ~to=S.json)
         OR (preferred for hot paths)
         S.encoder(s)(value)
# 4.   v->S.reverseConvertToJsonStringOrThrow(s, ~space=2)
       → v->S.decodeOrThrow(~from=s->S.reverse, ~to=S.jsonStringWithSpace(2))
# 5.   str->S.parseJsonStringOrThrow(schema)
       → str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)
# 6.   json->S.convertOrThrow(schema)           (3 in-memory calls)
       → json->S.parseOrThrow(~to=schema)
```

**Choice for #3** — `S.encoder` vs `decodeOrThrow(value, reverse(s), S.json)`:

- `S.encoder(schema)` allocates a hoisted closure that can be cached outside the
  hot path; the inline `decodeOrThrow` form re-derives the reversed schema each
  call. Hot serialisation paths (message envelopes, event log writes) should
  hoist the encoder once per spec. Cold paths (test assertions, codegen
  exporters) can use the inline form for terseness.
- For ergonomics inside generic functor code (`Spec.eventSchema` may come from a
  module argument), the inline form avoids needing to store the encoder
  alongside the schema.

A pragmatic call: introduce a tiny helper to keep call sites uniform and
isolate the alpha.5 vocabulary in one place. The shim lives in
`reventless-spec/src/util/Util_Sury.res` (not `reventless-core/src/util/` as
the first draft suggested — `reventless-spec` itself has 4 sury-using files
and is the lowest framework package using sury, so the shim has to sit
there):

```rescript
// reventless-spec/src/util/Util_Sury.res
let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
  value->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.json)
let toJsonString: ('a, S.t<'a>, ~space: int) => string = (value, schema, ~space) =>
  value->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.jsonStringWithSpace(space))
let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) =>
  json->S.parseOrThrow(~to=schema)
let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
  str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)
```

That keeps the diff per call site to a near-mechanical s/old/new and makes a
future sury-12 migration a one-file change. Inside `reventless-spec` the
shim is `Util_Sury`; from other packages it is `Reventless.Util_Sury`
(`reventless-spec` declares `namespace: "Reventless"`).

## Phase 1 investigation findings (2026-05-17)

Captured from the `sury-alpha5-phase1` branch experiment (snapshot commit
`bb689a73e`). The branch bumped sury to alpha.5 across all 9 framework +
adapter packages locally, dropped the `Util_Sury` shim into
`reventless-spec/src/util/`, and ran `pnpm exec rescript build` from
`reventless-spec`. Three things were learned **before any source-side port
happened**:

1. **Shim API signatures in the original analysis were wrong.** The plan and
   the migration-mapping table both showed `decodeOrThrow(value, from, to)`
   and `parseOrThrow(value, schema)` with positional arguments. The real
   alpha.5 signatures (from `Sury.resi:394–405`) use labeled args:
   `parseOrThrow: ('any, ~to: t<'value>) => 'value`,
   `decodeOrThrow: ('from, ~from: t<'from>, ~to: t<'to>) => 'to`. The table
   and code samples above have been corrected; the `Util_Sury` block now
   reads `~from=…, ~to=…`. This is the only correction needed at the shim
   level — call sites still match the alpha.4 pipe shape
   (`value->Util_Sury.toJson(schema)`).

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

2. **Error type/shape**: alpha.5 has a new `Exn` module and a different
   `S.Error` constructor. Any code that pattern-matches on sury errors (look
   for `S.error`, `S.$$Error`, `JsExn` against sury) needs review. None
   spotted in the initial grep but worth a second pass.

3. **sury-ppx alpha.2 + sury alpha.5 compatibility**: sury-ppx is pinned to
   alpha.2; the PPX emits `S.schema(s => …)` and `s.m(…)` calls that need to
   resolve against alpha.5's `S` module. Quick check: the PPX-emitted symbols
   (`schema`, the `s.m` builder helper) **are** present in alpha.5's exports.
   Likely OK, but warrants compiling a single PPX-using package against alpha.5
   to confirm before committing to the migration.

4. **Other consumers of removed APIs in transitive deps**: a Layer-builder
   re-resolve might also pull a new version of `rescript-relay` or similar
   that uses the alpha.4 API. Worth grepping the Layer 58 zip's `node_modules`
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
`Projection.res` to use them. With both packages bumped to sury alpha.5
locally and the helper in place, run the full `reventless-core` and
`reventless-local` test suites. This validates (a) the encoder-direction
equivalence question and (b) sury-ppx alpha.2 + sury alpha.5 compatibility on
a small surface.

**Phase 2 — bulk migration**: scripted s/old/new over the 76 affected `.res`
files plus `HeartbeatEntryPoint.mjs`. Each replaced call uses the
`Util_Sury` helper, not the raw `S.decodeOrThrow(reverse(…), …)` form, so the
diff is uniform.

**Phase 3 — remove the pin + ship**: delete the `^11.0.0-alpha.4` pin (or
bump to `11.0.0-alpha.5`) and let CI publish a new Layer. The pin
removal **and** Layer re-publish must happen in the same release window —
otherwise a Layer build between Phase 1's merge and Phase 3's release would
re-introduce the alpha.5 vs alpha.4 split.

**Phase 4 — delete `Util_Sury` (optional)**: if the helper turns out to add
nothing over inlining, fold it back. Most likely worth keeping as a sury-version
isolation seam.

## Validation plan

- All 802 existing framework tests (386 core + 416 in-memory) must pass on
  alpha.5 with no skip/xfail additions.
- Add 1-2 round-trip property tests: random typed state → encode → decode →
  equal-to-input. Cover at least one variant-with-payload event spec and one
  record state spec.
- After deploy: invoke `CatalogPluginHeartbeat-*` directly, assert the EP
  dispatcher logs show `EP→Plugin: Heartbeat(Catalog@…)` followed by a
  successful `applyCommandAction` (no "Aggregate Plugin doesn't exist").
- Query `Platform_Plugins`: should return ≥ 1 edge with non-null `name`,
  `version`, `status` after the first post-deploy heartbeat.

## Opportunities the alpha.5 upgrade unlocks

The migration is not just a like-for-like API swap — alpha.5 closes several
gaps that prior analyses called out as missing or worked around. Listed in
rough order of how directly they pay off, with cross-references to existing
analysis/plan documents.

### A. Replace the `js_nullable` workaround (direct fix)

**What's new:** alpha.5 exports `S.nullAsOption` — interprets `T | null →
option<T>` without admitting `undefined` into the union.

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

becomes, on alpha.5:

```rescript
let myOptionSchema = baseSchema->S.nullAsOption
```

Search target for the fix: every site importing `js_nullable` from
`sury/src/Sury.res.mjs` (currently used to make `apiSchemaFragment` survive
`jsonableValidation` in union variants).

### B. Hoisted parser / decoder closures for hot paths

**What's new:** `S.parser(schema): unknown => Output` and `S.decoder(schema):
Input => Output` return reusable closures, instead of recomputing the parser
on every call as `parseJsonOrThrow` did.

**Pain it removes:** Every event log replay, every projection update, every
Lambda command handler currently calls `S.parseJsonOrThrow(schema)` inline,
which means sury re-derives the parser on each invocation. With `parser`, the
closure is cached at module init.

```rescript
// alpha.4 hot path — re-builds parser per event
let event = json->S.parseJsonOrThrow(Spec.eventSchema)

// alpha.5 — build once, call many
let parseEvent = S.parser(Spec.eventSchema)
let event = parseEvent(json)
```

This is the most material runtime win: the Lambda cold/warm cycle does the
parser-construction work exactly once per spec, rather than per event. Likely
candidates to hoist first: `Message.res` (envelope decode/encode), `Projection.res`
(state load/save), and the EventLog operations.

### C. Native event schema versioning via `S.decoder(from, to)` / `S.to`

**What's new:** `decoder` takes a chain of schemas and threads input through
them. Combined with `S.to(schema, ~decode, ~encode)`, this gives bidirectional
schema transforms equivalent to the `Effect.Schema.transform` pattern that
`docs/plans/done/effect-library-integration.md` Tier 3 §10 wanted.

**Pain it removes:** That doc lists "no schema versioning" as a tier-3 gap, and
`docs/analysis/event-format-and-meta-review.md` calls out the wishlist item
"Free `dataschema` slot for sury / version migrations" — the underlying need
was bidirectional event migration on replay.

```rescript
// V2 schema with a migration from V1 stored events
let v2Schema =
  S.to(v1Schema, v2Schema,
    ~decode=(v1: V1.event) => migrate(v1),
    ~encode=(v2: V2.event) => downgrade(v2),
  )
```

Replay can then read both v1 and v2 records into a single typed view, removing
the current "rename a field and break replay" foot-gun without needing the
heavier Effect Schema migration discussed in `done/effect-library-integration.md`.

**Plan:** [`docs/plans/Backlog/sury-event-schema-versioning.md`](../plans/Backlog/sury-event-schema-versioning.md).

### D. `Exn` module — structured sury errors

**What's new:** `S.Exn` exposes a typed error type with the failure path,
expected schema, and received value already split out (instead of a stringly-
typed `JsExn.message`).

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
| A. `nullAsOption` replaces `js_nullable`     | CLAUDE.md memory; `done/api-component-graphql.md`                                       | `sury-alpha5-migration.md` Phase 2.3                                                | trivial        | direct |
| B. Hoisted `parser` / `decoder` on hot paths | (perf observation)                                                                      | `sury-alpha5-migration.md` Phase 3                                                  | small per spec | Lambda perf |
| C. Schema versioning via `S.decoder` chains  | `done/effect-library-integration.md` §10; `event-format-and-meta-review.md` #9          | `Backlog/sury-event-schema-versioning.md`                                           | medium         | unblocks event evolution |
| D. `S.Exn` structured errors                 | `given-when-then-specifications.md` §"opaque diff"                                      | `sury-alpha5-migration.md` Phase 2.4                                                | small          | observability |
| E. `isoDateTime` / `date`                    | `event-format-and-meta-review.md`                                                       | `sury-alpha5-migration.md` Phase 2.5                                                | small          | tighter schemas |
| F. `toJSONSchema` → SDL / OpenAPI            | `rejected/sury-vs-effect-schema.md` §6.1; `Backlog/api-component-openapi.md`            | `Backlog/typed-graphql-sdl-from-sury.md`                                            | medium         | typed APIs |
| G. Standard Schema v1 TS interop             | `typescript-client-feasibility.md` Blocker 1; `done/effect-library-integration.md` §10  | `Backlog/typescript-client-sdk.md`                                                  | small SDK      | TS clients |
| H. Drop `enableJson()` calls                 | (cleanup)                                                                               | `sury-alpha5-migration.md` Phase 2.1                                                | trivial        | clarity |

A, B, D, E, H land in the main migration plan (in-window cleanups). C, F, and
G are follow-on projects in their own backlog plans — the alpha.5 migration
makes them materially easier without being prerequisites.

## References

- Sury repo: <https://github.com/DZakh/sury>
- Standard Schema spec: <https://standardschema.dev/>
- alpha.5 type definitions (extracted from Layer 58):
  `node_modules/sury/src/S.d.ts` (after a fresh `pnpm install` if alpha.5 is
  in the lockfile)
- Inline-Lambda crash that triggered this:
  `reventless/reventless-aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs:5`
- Plans built on this analysis:
  - `docs/plans/sury-alpha5-migration.md` — main migration sweep
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
