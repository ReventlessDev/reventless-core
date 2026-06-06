# Plan: Migrate Reventless to Sury 11.0.0-alpha.5

**Status:** Draft
**Analysis:** [`docs/analysis/sury-alpha5-migration.md`](../analysis/sury-alpha5-migration.md)
**Triggering incident:** Lambda Layer `reventless-aws-alpha:58` shipped with
`sury@11.0.0-alpha.5` and crashed every heartbeat Lambda at init with
`SyntaxError: 'reverseConvertToJsonOrThrow' is not an export`.

## Goal

Move all Reventless framework packages off the alpha.4 sury API, bundle the
opportunistic cleanups that fall naturally out of the same diff, and re-ship
the Lambda Layer on sury alpha.5 — with no production downtime in between.

Out of scope for this plan (deferred to dedicated backlog items, see end of
document):
- Event schema versioning runtime (opportunity C in the analysis).
- `S.toJSONSchema → GraphQL SDL / OpenAPI` provider work
  (opportunity F — see existing `docs/plans/Backlog/api-component-openapi.md`).
- Standard Schema v1 TypeScript-client SDK (opportunity G — see
  `docs/analysis/typescript-client-feasibility.md`).

## What's already in place

- Layer 58 (`sury@11.0.0-alpha.5`) is the current live Layer for `alpha` —
  every heartbeat Lambda is failing init. Layer 57 (`sury@11.0.0-alpha.4`) is
  still available in AWS for rollback.
- Local `node_modules/sury` is pinned by `pnpm-lock.yaml` to alpha.4, so
  local builds and tests work today.
- Existing call inventory (from the analysis):
  - 76 `.res` files across 8 packages with one of: `S.reverseConvertToJsonOrThrow`,
    `S.parseJsonOrThrow`, `S.enableJson`, `S.convertOrThrow`,
    `S.parseJsonStringOrThrow`, `S.reverseConvertToJsonStringOrThrow`.
  - 1 hand-written `.mjs` — `HeartbeatEntryPoint.mjs`.
- sury-ppx stays on `11.0.0-alpha.2` (no alpha.5 release exists). It emits
  `S.schema(s => …)` + `s.m(…)` — both still present in alpha.5.

## Phases

### Phase 0 — Hot-fix the production deploy (pin sury alpha.4)

**Goal:** restore working deploys today, with zero behaviour change. This
buys the runway for the proper migration.

Steps:
1. In `reventless/reventless-{aws,core,infra,spec}/package.json`, change
   `"sury": "^11.0.0-alpha.4"` to `"sury": "11.0.0-alpha.4"` (exact, no caret).
2. `pnpm install` to update `pnpm-lock.yaml`. Confirm only `sury@11.0.0-alpha.4`
   resolves (no alpha.5 entry).
3. Commit and push to `alpha`. CI publishes new framework alphas → Layer
   builder resolves `sury@11.0.0-alpha.4` → Layer 59 ships → deploy workflow
   updates Lambdas. Verify heartbeat Lambdas no longer fail at init.

Validation:
- Invoke `CatalogPluginHeartbeat-*` and `OrderingPluginHeartbeat-*` manually
  post-deploy; no `UserCodeSyntaxError` in CloudWatch logs.
- `Platform_Plugins` GraphQL query returns the populated edges (heartbeat →
  Connect → projection → RM round-trip working end-to-end).

Risk: low. The pin downgrades the resolved version back to where production
was working two days ago.

### Phase 1 — Sury-isolation shim + smoke test

**Goal:** introduce a single `Util_Sury` module that wraps the alpha.5 vocab
behind alpha.4-compatible names, then port `Message.res` and `Projection.res`
as **pivot files** (the ones most likely to expose
behavioural-equivalence drift — open question #1 in the analysis). The build
won't compile with only those two ported, so this phase also has to port the
~55 transitive files in `reventless-spec`, `reventless-infra`,
`reventless-interop`, `reventless-core`, `reventless-local` as bulk
collateral — but those reads are mechanical; Message + Projection get the
careful review.

**Revisions captured from the Phase 1 investigation (commit `bb689a73e` on
`sury-alpha5-phase1`):**

- `Util_Sury` must live in **`reventless-spec/src/util/`**, not
  `reventless-core/src/util/`. `reventless-spec` itself has 4 sury-using files
  and is the lowest framework package using sury — the shim has to sit there
  so every dependent can reach it. From within `reventless-spec`, the shim is
  referenced as `Util_Sury`; from other packages it is `Reventless.Util_Sury`.
- The alpha.5 signatures of `decodeOrThrow` / `parseOrThrow` take **labeled**
  `~from` / `~to` arguments, not the positional form the earlier draft of
  this plan and the analysis doc both showed. The corrected shim is below.
- `S.t.Object` lost its `items: array<{name, location, schema}>` record in
  alpha.5 — only `properties: dict<t<unknown>>` remains. `DcbDecode.res` and
  `DcbTag.res` walk variant schemas via
  `Object({items}).find(item => item.location == "TAG")` to identify the
  discriminant; that introspection has to be rewritten to
  `Object({properties}).Dict.get("TAG")` (sury-ppx still emits the discriminant
  under the `"TAG"` key; the `items` / `location` concepts are gone). This
  rewrite was not in the original plan — see Step 4 below.

Steps:

1. Add `reventless/reventless-spec/src/util/Util_Sury.res`:
   ```rescript
   let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
     value->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.json)
   let toJsonString: ('a, S.t<'a>, ~space: int) => string = (value, schema, ~space) =>
     value->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.jsonStringWithSpace(space))
   let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) =>
     json->S.parseOrThrow(~to=schema)
   let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
     str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)
   ```
   (Function-name shapes are kept alpha.4-compatible — `value->Util_Sury.toJson(schema)`
   matches `value->S.reverseConvertToJsonOrThrow(schema)` at the call site —
   so the subsequent bulk replace stays mechanical, even though the inside of
   the shim now uses labeled args.)
2. In a feature branch, locally bump `"sury": "11.0.0-alpha.4"` →
   `"11.0.0-alpha.5"` in all 9 framework + adapter packages **and** run
   `pnpm install` to refresh the lockfile to alpha.5. (The Phase 0 audit
   already established 9 packages — `reventless-{spec,infra,interop,core,
   in-memory,gwt,codegen,aws}` + `rescript-pulumi-aws` — not the 4 the
   first draft named.)
3. Pivot port — manually rewrite `reventless-core/src/Message.res` and
   `reventless-core/src/Projection.res` to call `Util_Sury.toJson` /
   `fromJson` instead of `S.reverseConvertToJsonOrThrow` /
   `S.parseJsonOrThrow`. Delete `S.enableJson()` calls in any file these
   pull in. These are the files most likely to expose behavioural
   divergence — the rest of Phase 1 can be scripted.
4. **Schema-introspection rewrite** (new in this revision). In
   `reventless-spec/src/components/DcbDecode.res` and `DcbTag.res`, replace
   ```rescript
   | Object({items, properties}) =>
     let tagName = items
       ->Array.find(item => item.location == "TAG")
       ->Option.flatMap(item => switch item.schema { | String({const}) => Some(const) | _ => None })
   ```
   with the alpha.5 equivalent — extract the discriminant by looking up the
   `"TAG"` key in `properties`:
   ```rescript
   | Object({properties}) =>
     let tagName = properties
       ->Dict.get("TAG")
       ->Option.flatMap(s => switch s { | String({const}) => Some(const) | _ => None })
   ```
   The `PayloadLess` vs `WithFields` heuristic in `DcbDecode.buildVariantLookup`
   (line 32: `properties->Dict.keysToArray->Array.length == 0` → `PayloadLess`)
   also needs auditing: in alpha.4 `properties` was the payload-only fields,
   in alpha.5 it includes `TAG`. The check probably becomes `<= 1` (only the
   TAG entry), but confirm against fixture round-trips.
5. Bulk-port the remaining ~55 collateral files (spec, infra, interop, core,
   in-memory) via scripted s/old/new on the call-site forms (`S.parseJsonOrThrow`
   → `Util_Sury.fromJson`, etc.). Inside `reventless-spec` use unqualified
   `Util_Sury.…`; outside use `Reventless.Util_Sury.…`.
6. Run the `reventless-core` (386) and `reventless-local` (416) test
   suites. Resolve any failures — likely categories:
   - Behavioural equivalence drift between `reverseConvertToJsonOrThrow` and
     `decodeOrThrow(value, ~from=reverse(s), ~to=S.json)` under `S.transform` /
     `@s.matches` / refinements (open question #1) — document and adjust the
     helper.
   - Variant-tag introspection in `DcbDecode`/`DcbTag` if the
     `properties.get("TAG")` translation in Step 4 is wrong.
   - Other `S.t` structural changes we haven't hit yet.
7. **Do not merge to alpha yet.** Phase 1 is a learning step; leave the
   branch open with notes on what worked and what didn't.

Validation:
- Both test suites green on alpha.5 after the pivot port + bulk collateral +
  schema-introspection rewrite.
- No new compiler warnings.
- Add 2 round-trip property tests under `reventless-core/tests/`: a typed
  state record and a variant-with-payload event each survive
  `value → toJson → fromJson → equal-to-input` over a randomly generated set.
- One DCB-tag round-trip test exercising `extractTags` /
  `DcbDecode.makeDecoder` on a variant schema, to validate the
  `properties.get("TAG")` translation against a sury-ppx-emitted union.

If Phase 1 surfaces showstoppers (PPX incompatibility, semantic divergence we
can't shim, further `S.t` structural breaks), stop here and re-plan.
Production is still on the Phase-0 pin during this entire phase.

### Phase 2 — Bulk migration with opportunistic cleanups A, D, E, H

**Goal:** rewrite the remaining `.res` files to alpha.5 via the
`Util_Sury` shim, and fold in the cheap analysis-opportunity wins that touch
the same files.

**Scope revision (from Phase 1 investigation):** Phase 1 ports ~55 files
across `reventless-spec`, `reventless-infra`, `reventless-interop`,
`reventless-core`, `reventless-local` as collateral. Phase 2 therefore
ports the ~21 remaining files in `reventless-aws` (2), `reventless-gwt` (10),
`reventless-codegen` (6), `rescript-pulumi-aws` (1), plus the hand-written
`HeartbeatEntryPoint.mjs` and the example plugin packages.

Steps:
1. Scripted rewrite using `sed` / `comby` over the 76 affected files:
   - `S.parseJsonOrThrow(s)` → `Util_Sury.fromJson(_, s)`
   - `S.reverseConvertToJsonOrThrow(s)` → `Util_Sury.toJson(_, s)`
   - `S.reverseConvertToJsonStringOrThrow(s, ~space=N)` →
     `Util_Sury.toJsonString(_, s, ~space=N)`
   - `S.parseJsonStringOrThrow(s)` → `Util_Sury.fromJsonString(_, s)`
   - `S.convertOrThrow(s)` (3 sites in `reventless-local/src/Platform.res`)
     → `Util_Sury.fromJson(_, s)` (the calls take JSON values).
   - `S.enableJson()` (41 sites) → delete entire line (opportunity H).
2. Update `reventless/reventless-aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs`
   — the only hand-written `.mjs` consumer — to import the new helper or
   inline `decodeOrThrow(value, reverse(schema), json)`.
3. **Opportunity A** — Replace `js_nullable` workaround.
   - Grep for `external _jsNullable` / `import "sury/src/Sury.res.mjs"`.
   - At each site, swap to `baseSchema->S.nullAsOption`.
   - Verify the `jsonableValidation` regression from
     `docs/plans/done/api-component-graphql.md` does not return — run the
     affected union-variant schemas (PluginExtensionPointSpec, etc.) through
     a parse round-trip.
4. **Opportunity D** — Adopt `S.Exn` in framework error paths.
   - In `reventless-core/src/util/`, add an `Util_SurErr.fromExn(exn) =>
     option<{path, expected, received}>` helper using `S.Exn`.
   - Wire it into the existing `Logger`-level catch in
     `ExtensionPoint_Callback.applyCommandAction` and
     `CommandTopic_Helpers` so sury parse failures log structured fields
     instead of opaque `JsExn.message` strings.
   - Defer wider rollout (test-runner diffs, etc.) to a follow-up — only
     framework-side production logs in this pass.
5. **Opportunity E** — Tighten ISO 8601 date-time schemas.
   - Replace `time: string` with `time: @s.matches(S.isoDateTime) string` (or
     equivalent sury-ppx form) on `Message.meta`, `PluginReadModelSpec.state.
     statusChange.at`, and any other meta-style timestamp field.
   - Audit `Message.nowAsISOString()` callers to ensure outputs validate.
   - Stop short of converting payload values typed as `Date` — that's a wire
     format change, defer.
6. **Opportunity H** — `S.enableJson()` deletions covered by step 1 above.
7. Restore the lockfile to keep sury on `11.0.0-alpha.4` for now — the pin
   from Phase 0 stays in place; Phase 2 is purely about preparing the source
   to be alpha.5-ready. Phase 4 flips the version.

Validation per package:
- `pnpm --filter <pkg> run build` — zero warnings.
- `pnpm --filter <pkg> test` — all existing tests pass against alpha.4 still
  (the `Util_Sury` shim is API-compatible with the alpha.4 names it covers).
- Per-package commit; reverting one package is independent.

Don't bundle opportunities B (parser hoisting), C, F, G into Phase 2 — those
are scoped separately.

### Phase 3 — Hoist parsers / decoders on hot paths (opportunity B)

**Goal:** convert the `Util_Sury.fromJson(_, schema)` calls on identified hot
paths into module-init-time `S.parser(schema)` closures, so each Lambda
invocation skips the per-call parser-construction work.

Hot paths to target (in priority order):
1. `Message.splitMessage` / `combineMessage` — every command and event passes
   through these in Lambdas and tests.
2. `Projection.res` state load/save.
3. `EventLog_Operations` event replay.
4. `Aggregate_Callback` command-body decode.
5. `StateChangeSlice_Callback` / `InboundTranslationSlice_Callback` / `Outbound`.
6. `DcbEventLog_Operations` event decode.

For each, the pattern:
```rescript
// before
let event = json->Util_Sury.fromJson(Spec.eventSchema)

// after
let parseEvent = S.parser(Spec.eventSchema)
// ...
let event = parseEvent(json)
```

Functor-internal calls (where `Spec` comes from a module argument) build the
parser once inside the functor body, not on each operation.

Validation:
- All existing tests pass.
- A simple micro-benchmark (run via `node --enable-source-maps -e ...`) that
  decodes 100k pre-stringified events shows lower per-event time than the
  inline form. Optional — record numbers in the plan, don't block on them.

This phase is independent of Phase 4; can ship before or after.

### Phase 4 — Flip to sury alpha.5 + republish Layer

**Goal:** remove the Phase-0 pin and ship a Layer carrying the
alpha.5-compatible framework.

Steps:
1. In `reventless/reventless-{aws,core,infra,spec}/package.json`, change
   `"sury": "11.0.0-alpha.4"` to `"sury": "11.0.0-alpha.5"` (exact again; do
   not reintroduce `^` until alpha graduates).
2. `pnpm install`; confirm only `sury@11.0.0-alpha.5` resolves.
3. Full local build + test pass across reventless-core, reventless-local,
   reventless-aws, reventless-gwt, reventless-codegen, reventless-spec,
   reventless-interop, plus the example plugins.
4. Commit and push to `alpha`. CI publishes new alphas; Layer 60 builds with
   `sury@11.0.0-alpha.5`; deploy workflow rolls Lambdas onto it.
5. Post-deploy verification: identical to Phase 0 (heartbeats clean,
   `Platform_Plugins` returns entries).

Validation:
- All eight framework packages build + test green locally before push.
- Post-deploy CloudWatch sweep over a 30-minute window after Lambda update:
  zero `UserCodeSyntaxError`, `parseError`, or unhandled sury exceptions.

The Phase-0 pin and the Phase-4 unpin must land in the **same release
window**. Otherwise a Layer build between them would re-introduce the
alpha.5 mismatch.

### Phase 5 — Optional: collapse `Util_Sury` (or keep as a seam)

After Phase 4 lands and a release cycle confirms alpha.5 is stable, decide:
- **Keep `Util_Sury`** as a sury-version isolation seam — small ergonomic
  cost, makes any future sury-12 swap a one-file diff.
- **Inline it** — fold `toJson` → `decodeOrThrow(value, reverse(schema),
  S.json)`, etc. at every call site, delete the module.

Default to keep unless team consensus is to inline. Either way, this is a
post-stability decision, not part of the migration sweep.

## Validation checklist (cross-phase)

- [ ] Phase 0: production Lambdas no longer crash at init; `Platform_Plugins`
      query returns ≥ 1 edge with non-null `name`/`version`/`status`.
- [ ] Phase 1: `Util_Sury` shim exists; `Message.res` + `Projection.res`
      ported; both core test suites green on alpha.5 locally.
- [ ] Phase 1: 2 new round-trip property tests for typed-state and
      variant-payload events.
- [ ] Phase 2: 76 files swept; zero `S.enableJson` / `js_nullable` /
      `reverseConvert*` / `parseJson*` / `convertOrThrow` remain in
      `--include="*.res"` (sury and lib excluded).
- [ ] Phase 2: per-package tests + zero compiler warnings.
- [ ] Phase 3: identified hot paths hoist parsers at module init.
- [ ] Phase 4: pin removed; all framework packages build + test on alpha.5;
      Layer 60 deployed; 30-minute log sweep clean.

## Risk register

| Risk                                                                                       | Likelihood | Impact | Mitigation                                                                       |
| ------------------------------------------------------------------------------------------ | ---------- | ------ | -------------------------------------------------------------------------------- |
| Behaviour divergence in `decodeOrThrow(value, reverse(s), S.json)` vs `reverseConvertToJsonOrThrow` under `S.transform` / refinements | medium     | high   | Phase 1 round-trip property tests catch it before bulk migration                |
| sury-ppx alpha.2 + sury alpha.5 emit incompatible code                                     | low        | high   | Phase 1 runs the full test suite on alpha.5 with a real PPX-using surface       |
| `S.nullAsOption` does not fully replace `js_nullable` in union variants (jsonableValidation regression returns) | low        | medium | Phase 2 step 3 explicitly re-tests `apiSchemaFragment`-style union variants     |
| Layer 60 build picks up another transitively-bumped library that breaks                    | low        | medium | Phase 4 verifies the locally-resolved tree before push; rollback to Layer 59     |
| `S.isoDateTime` rejects a timestamp shape we currently emit                                | low        | low    | Phase 2 step 5 audits `nowAsISOString` callers before flipping                  |

## Deferred follow-ups (own backlog items)

These came out of the analysis but are too large to bundle into the
migration sweep. They become materially easier once Phase 4 lands.

1. **Opportunity C — event schema versioning via `S.decoder` chains.**
   New plan: `docs/plans/Backlog/sury-event-schema-versioning.md` (to be
   written). Background:
   `docs/plans/done/effect-library-integration.md` §10,
   `docs/analysis/event-format-and-meta-review.md` #9.

2. **Opportunity F — type-driven GraphQL SDL via `S.toJSONSchema`.**
   Threads into the existing `docs/plans/Backlog/api-component-openapi.md`
   plan; both providers can consume the same converter. Will need a
   prerequisite review of `QueryDbResolvers_GraphQL.res` /
   `CommandGeneratorResolvers_GraphQL.res` to identify the swap surface.
   Background: `docs/analysis/rejected/sury-vs-effect-schema.md` §6.1.

3. **Opportunity G — Standard Schema v1 TypeScript SDK.**
   Threads into `docs/analysis/typescript-client-feasibility.md` Blocker 1
   resolution. New plan: `docs/plans/Backlog/typescript-client-sdk.md`
   (to be written; cite the rejected sury-vs-effect-schema analysis and
   the typescript-client-feasibility doc).

## References

- Analysis: `docs/analysis/sury-alpha5-migration.md`
- Sury repo: <https://github.com/DZakh/sury>
- Standard Schema: <https://standardschema.dev/>
- Related: `docs/plans/done/api-component-graphql.md`,
  `docs/plans/done/effect-library-integration.md`,
  `docs/analysis/event-format-and-meta-review.md`,
  `docs/analysis/typescript-client-feasibility.md`,
  `docs/analysis/given-when-then-specifications.md`,
  `docs/plans/Backlog/api-component-openapi.md`.
