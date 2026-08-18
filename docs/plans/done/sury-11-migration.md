# Plan: Migrate Reventless to Sury 11 (landed on 11.0.0-rc.1)

**Status:** ✅ **Migration complete** — phases 0, 1, 2 and 4 landed; squash-merged to `alpha` on 2026-08-18. Executed on branch `sury-11-migration` (was `sury-alpha8-wip`). Phase 3 (parser hoisting) was **not** executed and moves to the deferred follow-ups below; the Layer rebuild happens on the push.
**Analysis:** [`docs/analysis/done/sury-11-migration.md`](../analysis/done/sury-11-migration.md)

> **Completion (2026-08-18) — landed on `11.0.0-rc.1`, merged to `alpha`.**
> The branch was first brought up to date with `alpha`, then squash-merged, so the
> migration arrives as one commit rather than the fourteen-commit prerelease
> ladder. Final state: **346 suites, 3450 tests**, zero compiler warnings, both
> GraphQL contract goldens matching.
>
> - **`rc.0` → `rc.1` needed exactly one source change.** `S.url` now decodes to a
>   `URL` *instance*, so `Url.res` moves to `S.uri`, the string-preserving arm.
>   This is more than a typing detail: `new URL("http://x").href` normalises to
>   `http://x/`, and the value is written to an append-only log, so the address has
>   to survive as the caller wrote it. `S.uri` still rejects what does not parse.
>   The `http`/`https` allowlist remains what closes the `javascript:` hole, since
>   `S.uri` accepts that scheme like the old `S.url` did.
> - **Catching up with `alpha` cost more than the bump itself.** `alpha` had moved
>   273 commits ahead, and its newer code was written against sury API that rc.1
>   removed: `Union` → `AnyOf`, `Object({items})` → `Object({properties})`, and
>   `convertOrThrow` / `reverseConvertToJson*OrThrow` / `parseJsonOrThrow` /
>   `enableJson` onto `Util_Sury`. Git could not flag any of it — they were clean
>   auto-merges that simply no longer compiled.
> - **One behavioural defect the merge would have introduced silently.** `alpha`
>   split array-unwrapping out of `Reference.getTarget` into `getFieldTarget`,
>   while this branch's `toEventDef` still called `getTarget` — so plural
>   (`array`) references stopped reaching the manifest. Caught by
>   `PluginStructureTest`, fixed by using `getFieldTarget` as the command side
>   already did.

> **Update (2026-08-05) — the rc.0 workaround is gone too; the tree is now
> workaround-free on rc.0.** The maintainer answered
> [#347](https://github.com/DZakh/sury/issues/347): *"I'll improve the case, but for
> you here `S.shape` or `S.object` would be a better fit. And they wouldn't cause
> such an error."* He is right, and taking the advice removed more than it was
> aimed at. Full suite green: **301 suites, 2731 tests** (2724 + 7 new
> regression tests), no skips, zero compiler warnings.
>
> - **`Offload`'s union arms are now declared, not hand-written.** `S.object` for
>   the sentinel-keyed reference arm, `S.shape` for the inline arm, and
>   `optionSchema` back to the simple `S.nullAsOption(schema(inner))`. A
>   `S.transform` arm is opaque — sury cannot know what it accepts, so it must
>   offer every value to the arm's own serializer, which is why an absent optional
>   arrived as a raw `undefined`. A declared arm is discriminated on structure and
>   never runs user code to find out. Leaving even one arm as a transform
>   reproduces the failure, so this is all-or-nothing per union.
> - **It fixed a second, unreported defect that no test covered:** a `json`-typed
>   union arm cannot chain into a non-JSON target, so an `Offloaded` value encoded
>   to `S.jsonString` threw while the same value encoded to `S.json` succeeded.
>   Latent rather than live — today's `toJsonString` call sites on that path pass
>   the inner value's schema, not the codec — but it would have surfaced the first
>   time a message carrying an offloaded field was serialized to a string.
> - **One change had to come with it.** A declared reference arm is *object-typed*,
>   where the json-transform arm was `unknown`, and `Message.fillMissingDefaults`
>   resolved an object value in an `anyOf` to the *first object-typed member*. A
>   legacy inline payload missing a later-added field therefore healed into a
>   reference with an empty key — and then decoded cleanly, i.e. silent corruption
>   of replayed history rather than an error. The walker now picks the object member
>   declaring the most of the value's own keys, ties keeping the earliest. This was
>   a latent fragility for *any* union of two object shapes; offload was simply the
>   first union with two.
> - **The required-scalar tripwire gained eight lines, and should have.**
>   `.apiSchemaFragment.$offload.*` and `.structure.$offload.*` are not new fields —
>   they have been persisted since `@offload` existed. The guard could not see them
>   through an opaque transform arm, so it had been checking only the inline half of
>   every offloadable field. Both halves are covered now.
> - **`Offload` held the only `S.union` and the only `S.transform` in the whole
>   source tree**, so there is no second site carrying this hazard.
>
> Writeup: [`docs/analysis/done/sury-rc0-optional-union-encode.md`](../analysis/done/sury-rc0-optional-union-encode.md).
> #347 stays open upstream, but nothing here depends on it — there is no workaround
> left to revisit if it lands. **Still pending before merge, unchanged:** the Layer
> republish + Phase 4 post-deploy verification.

> **Update (2026-08-04) — bumped alpha.11 → `11.0.0-rc.0`; the last workaround is
> gone.** All 67 `sury`/`sury-ppx` pins + lockfile moved to `11.0.0-rc.0` (exact,
> no caret). Full suite green: **276 suites, 2260 tests, no skips, zero compiler
> warnings** — the same counts alpha.11 reached, so nothing regressed.
>
> - **The alpha.11 optional-leading-literal-union regression is FIXED.** Verified
>   twice: all seven rows of the repro matrix pass on rc.0, and a real
>   `PolicyDocument.policySchema` encode round-trips `"*"`, single-string,
>   array-valued and absent `Action`/`Resource` fields. The `@as("*")` arms in
>   `rescript/pulumi-aws/src/IAM/PolicyDocument.res` are back in **first** position
>   and the workaround comment is deleted. **No sury workarounds remain in the
>   tree.** The issue was never filed and no longer needs to be.
> - **Only one source change was required by rc.0:** the schema-introspection
>   variant `Union({anyOf})` was renamed to `AnyOf({anyOf})` (the payload field
>   keeps the name `anyOf`). 32 pattern-match sites across 12 files in
>   `reventless-core`, `reventless-spec`, `reventless-local` and `reventless-aws`
>   — a mechanical rename. `String({const})`, `Object({properties})` and
>   `Array({additionalItems})` are all unchanged, so the `properties`/`Dict.get("TAG")`
>   introspection this branch already did carries over untouched.
> - **The same rename bites at runtime, where the compiler cannot see it.**
>   `Message.fillMissingDefaults` is a `%raw` walker that switches on the runtime
>   `schema.type` string; rc.0 renamed that tag from `"union"` to `"anyOf"`, so the
>   walker silently stopped healing tagged-union members. It compiled fine and
>   failed only in `MessageTest` (the replay/schema-migration-on-read path). Same
>   lesson as `DcbCommandTopicEntryPoint.mjs` in alpha.11: **on a sury bump, grep
>   the untyped surfaces (`%raw`, hand-written `.mjs`) for schema-shape literals.**
> - **`S.resi` no longer ships** — rc.0 has only `S.res`. That is now the
>   authoritative reference for this codebase (the earlier "follow `S.resi`, not the
>   `.d.ts`" note still holds in spirit: read the ReScript source, not the TypeScript).
> - **Watch out when switching to this branch:** `tests/**/*.res.mjs` is gitignored,
>   so checking out from `alpha` leaves alpha-only compiled test outputs on disk.
>   Twelve of them ran against sources this branch does not have and read as sury
>   failures. They are checkout artefacts — delete any `tests/*.res.mjs` with no
>   sibling `.res`. Relatedly, `pnpm install` triggered a compiler-update clean that
>   wiped 675 *tracked* `src/**/*.res.mjs`; the root `build` chain re-emitted all of
>   them (`git ls-files --deleted` back to 0).
>
> **Caught up to `alpha` the same day (162 commits).** Full suite green after the
> merge: **301 suites, 2724 tests, no skips, zero compiler warnings**. What the
> merge added on top of the pin bump:
>
> - **rc.0 has its own regression, and this one we had to work around.** Encoding
>   an *absent* optional field whose schema is a `nullable`-wrapped union of
>   transforms descends into the union's serializers with a raw `undefined`
>   instead of short-circuiting to null — an uncatchable `TypeError`. alpha.11
>   short-circuits correctly, so it is new in rc.0. It hit `@offload`, i.e. every
>   message whose offloadable field was absent. Worked around in
>   `Offload.optionSchema` by building the optionality *into* the union
>   (`S.literal(JSON.Null)` arm first, every arm taking `option<payload<'a>>`), so
>   the absent case is a matchable `None` rather than a raw `undefined`. Repro and
>   writeup in
>   [`docs/analysis/done/sury-rc0-optional-union-encode.md`](../analysis/done/sury-rc0-optional-union-encode.md);
>   **filed upstream as [DZakh/sury#347](https://github.com/DZakh/sury/issues/347)**.
>   Revisit `Offload.optionSchema` if it is fixed — the wrapped form is simpler, and
>   the built-in union exists only to dodge this bug. Two details keep the workaround
>   behaviour-preserving: the
>   none-arm must be **null-typed** (not json-typed) so the union still advertises
>   `has.null`, which `Message.fillMissingDefaults` reads to heal an absent field
>   on replay; and it must encode to an explicit `null`, not an omitted key, so the
>   wire form stays byte-identical to what is stored.
> - **`sury/src/Sury.res.mjs` no longer exists**, so alpha's
>   `@module("sury/src/Sury.res.mjs") external _jsNullable … = "js_nullable"` was a
>   runtime-missing import. The function survives, re-exported from `"sury"` as
>   `nullable`. This is the third hand-written/untyped surface a sury bump has
>   broken invisibly to the compiler, after `HeartbeatEntryPoint.mjs` and
>   `DcbCommandTopicEntryPoint.mjs`.
> - **Further rc.0 API drift the merge surfaced**, none of it hard: `S.url`/`S.email`
>   became schema *values* rather than refinements (`S.string->S.url` → `S.url`);
>   `S.parseOrThrow` requires the `~to` label; `S.enableJson()` is gone; `S.Error`
>   is gone as a ReScript exception constructor (sury throws a plain JS `SuryError`,
>   so its message comes off `JsExn`); `S.refine` is a predicate (alpha had added a
>   second effect-context site in `Semantic.refined`, plus `Money`/`GeoPoint`); and
>   `Array({items})` holds `array<t<unknown>>`, not records with `.schema`.
> - The `Union` → `AnyOf` rename applied to 4 more sites alpha added while the
>   branch sat idle. The sweep is idempotent, so re-running it over a merged tree
>   is the right move after every catch-up.
>
> **Still pending before merge:** the Layer republish + Phase 4 post-deploy
> verification (heartbeats clean, `Platform_Plugins` populated). Everything above
> is local evidence only — nothing has run on AWS.

> **Update (2026-07-28) — caught up to `alpha` and bumped to alpha.11; no known
> sury blockers remain.** All 34 `sury`/`sury-ppx` pins + lockfile moved to
> `11.0.0-alpha.11` (exact, no caret). The branch had fallen 358 commits behind
> `alpha`; a catch-up merge landed it, with five things worth recording:
>
> - **The framework packages were renamed on `alpha`** (`reventless/reventless-spec`
>   → `reventless/spec`, `reventless-local` → `local`, …) and
>   `reventless-vscode-protocol` moved out of this repo. Git paired the renames for
>   every file the branch had *modified*, so the careful work (DcbTag/DcbDecode
>   `properties`/`Dict.get("TAG")` introspection, the `S.nullAsOption` conversions,
>   the `Message.res` pivot) came across intact. Only `Util_Sury.res` — *added* on
>   the branch, so no rename to follow — stranded at the old path and was moved by
>   hand to `reventless/spec/src/util/`.
> - **The mechanical sweep is re-runnable and was re-run over the merged tree** —
>   25 files, 57 call renames, 1 `S.enableJson()` deletion — picking up the sury
>   call sites `alpha` added while the branch sat idle. Files already migrated have
>   no matches, so the sweep is idempotent.
> - **`S.refine` changed shape in alpha.11**: the alpha.4 effect-context form
>   (`S.refine(s => value => … s.fail(why))`) is now a plain predicate
>   (`S.refine(value => bool, ~error=?)`). One site — `StorageRef.forStore` — used
>   the old form. Migrated to the predicate; the per-value reason `fromString`
>   returns is no longer threaded into the schema error (no test asserted it, and
>   `fromString` remains the API for callers that need the specific rule).
> - **`S.res.mjs` stopped re-exporting `json`.** `DcbCommandTopicEntryPoint.mjs` —
>   a hand-written entry point `alpha` added, and the second such consumer after
>   `HeartbeatEntryPoint.mjs` — imported `{ json } from "sury/src/S.res.mjs"` and
>   died at module link with *"does not provide an export named 'json'"*. It now
>   imports from `"sury"`, the same binding the compiled ReScript resolves. Worth
>   remembering that hand-written `.mjs` is invisible to the compiler, so a sury
>   bump only surfaces there at test/runtime.
> - **`Message.fillMissingDefaults` walked the alpha.4 schema shape.** The
>   schema-migration-on-read walker (`%raw`, added on `alpha` after the branch
>   forked) read object fields as `schema.items[i].location` / `.schema`, which
>   sury 11 replaced with `schema.properties` (name → schema), and matched
>   tagged-union members through the same `items`/`location` pair. Both are now
>   `properties`-based — the identical rewrite the branch had already applied to
>   `DcbTag`/`DcbDecode`/`SchemaWalker`. Everything else the walker relies on
>   (`has.null`, `anyOf[].const`, array `additionalItems`) is unchanged in
>   alpha.11, verified by dumping live schema objects.
>
> **FACET 2 is FIXED in alpha.11** (upstream #311, closed): nested `None` optional
> fields are omitted on encode again, as alpha.4's `reverseConvertToJsonOrThrow`
> did. The three `ResolvedOutputsTest` cases that were `test.skip`-ped are restored
> and pass. With facet 1 already fixed in alpha.10, **neither bug that blocked this
> migration remains — the full suite is green (2252/2252, no skips).**
>
> **One NEW upstream regression came in with alpha.11**, found by two AWS tests that
> `alpha` added while the branch sat idle: compiling the encoder for an *optional*
> field whose union schema *leads with a literal* and has ≥3 members throws a raw
> `TypeError` out of `inlinedValueFromString`. That is the AWS IAM policy grammar
> (`"Action": "*" | string | array`), so every generated policy document failed to
> encode — a deploy-path break, not a test artefact. alpha.10 is unaffected.
> Worked around by declaring the `"*"` arm last in `PolicyDocument.actions` /
> `resources`; for an `@unboxed` variant that changes neither the encoded JSON nor
> the decoded runtime value. Repro table + ready-to-post issue in
> [`docs/analysis/done/sury-alpha11-optional-leading-literal-union.md`](../analysis/done/sury-alpha11-optional-leading-literal-union.md)
> — never filed; **fixed upstream in rc.0 and the arm order is reverted** (see the
> 2026-08-04 note above).
>
> If the workaround is judged too speculative to carry, alpha.10 is a one-command
> revert of the pins — the cost is facet 2 returning, i.e. the same 3 skipped
> `ResolvedOutputsTest` cases and the blocked cross-stack import of a sortless
> resource.
>
> **Still pending before merge:** Layer republish + the Phase 4 post-deploy
> verification (heartbeats clean, `Platform_Plugins` populated).

> **Update (2026-07-15) — bumped alpha.8 → alpha.10 on the same branch.** All 34
> `sury`/`sury-ppx` pins + lockfile moved to `11.0.0-alpha.10`; whole monorepo
> builds green, zero warnings. The alpha.8 external shim rename (`Sury.res.mjs` →
> `S.mjs`, `js_nullable` → `nullable`) did not bite — the branch already migrated
> those call sites to `S.nullAsOption`. One drift fixup was needed: `alpha` added a
> `@groupBy` UI-hint whose PPX emits a `groupBy` field, so `StateAnnotations.
> stateAnnotationSpec` gained `groupBy: option<string>` and three test fixtures
> gained `groupBy: None` (this branch predates that feature).
>
> **FACET 1 (the reported bug) is FIXED in alpha.10** — the `@s.matches(nullAsOption)`
> reverse transform now applies at `array<record>` depth. `ResolvedOutputsTest`
> fixture reverted to `sortKey: None`; the old `test.todo` is now a passing
> regression guard. **FACET 2 remains** (plain-`None` optional → `undefined`
> rejected as non-jsonable inside a `JSON`-typed field on encode); 3 tests stay
> `test.skip`-ped, tracked in
> [`docs/analysis/done/sury-alpha10-undefined-optional-in-json.issue.md`](../analysis/done/sury-alpha10-undefined-optional-in-json.issue.md).
> **Still pending before merge:** catch up to `alpha` (branch is ~193 commits
> behind — ~18 real `.res` conflicts), then Layer republish.

> **Execution log (2026-07-04) — branch `sury-alpha8-wip` (now `sury-11-migration`).** Full mechanical
> migration done: sury + sury-ppx → `11.0.0-alpha.8` across all 33 package.json
> pins + lockfile; `Util_Sury` shim (`parseOrThrow`/`decodeOrThrow` labeled args,
> encode = `decodeOrThrow(~from=schema, ~to=S.json)`); ~90 `.res` files ported;
> `js_nullable(x, ())` → **`S.nullAsOption`** (the alpha.8 `js_nullable(_, undefined)`
> returns a bare `x|null` union that rejects `None` — root cause of most failures);
> sury-11 schema introspection `items`/`location` → `properties`/`Dict.get("TAG")`
> in DcbTag/DcbDecode/DcbValidation/SchemaWalker/Plugin_Structure/SchemaType/
> GraphQL_FragmentGenerator; `Array.items` → `additionalItems` in SchemaType;
> protocol golden + LogFormat expectation updated for benign alpha.8 JSON key
> reordering. **Whole monorepo builds green; all tests pass** — spec 80, core 491,
> local 475, aws 139, gwt 195, protocol 90, interop 47 pass / **3 skip + 1 todo**.
> The 4 non-passing are xfail'd against a confirmed sury alpha.8 upstream bug
> ([`docs/analysis/done/sury-alpha8-nullasoption-reverse-bug.md`](../analysis/done/sury-alpha8-nullasoption-reverse-bug.md)):
> `@s.matches(nullAsOption)` reverse transform is dropped when reached through a
> multi-variant union inside `array<record>` in an object (interop resolvedOutputs),
> plus nested plain-`None` optionals serialising to `undefined` inside `JSON`-typed
> fields. **Before merge:** file the sury upstream issue; re-run Phase 4 (flip pins
> confirmed done here; Layer republish still pending); the interop cross-stack
> import of a sortless resource stays blocked until sury fixes it.
**Triggering incident:** Lambda Layer `reventless-aws-alpha:58` shipped with
`sury@11.0.0-alpha.5` and crashed every heartbeat Lambda at init with
`SyntaxError: 'reverseConvertToJsonOrThrow' is not an export`.

> **Re-target update (2026-07-04), verified by a compile+run spike.** Target
> moved from `alpha.5` to the current **`11.0.0-alpha.8`** (see the analysis's
> re-target note). What the spike (a throwaway package on `sury@alpha.8` +
> `sury-ppx@alpha.8`, built + run) established for this plan:
> - ✅ **The blocker is gone:** `sury-ppx@11.0.0-alpha.8` exists and compiles
>   `@schema` types against `sury@alpha.8`. So "sury-ppx stays on alpha.2" below
>   no longer applies — bump the ppx to `alpha.8` **alongside** sury.
> - ✅ **The ReScript API is the alpha.5-corrected form** — `parseOrThrow(~to=)`
>   and `decodeOrThrow(~from=, ~to=)` (labeled args) and `nullAsOption` are all
>   present. The shim/steps below written against that form are **correct as-is**
>   (encode = `value->S.decodeOrThrow(~from=schema, ~to=S.json)`, spike-verified).
> - ⚠️ Do **not** follow sury's TypeScript `.d.ts` (it diverges — drops `*OrThrow`,
>   adds `encoder`). `S.resi` is authoritative for this ReScript codebase; there
>   is **no `S.encoder`**.
> - 📌 `S.Exn` (opportunity D) has no ReScript module → re-scope. Bidirectional
>   transforms (event versioning) use `S.transform`, not `S.to(~decode,~encode)`.
> - All `alpha.5` version strings in the phase steps below should read `alpha.8`,
>   except the historical Layer-58 incident.

## Goal

Move all Reventless framework packages off the alpha.4 sury API, bundle the
opportunistic cleanups that fall naturally out of the same diff, and re-ship
the Lambda Layer on the current sury 11 (alpha.8) — with no production downtime
in between.

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
- sury-ppx bumps to `11.0.0-alpha.8` **alongside** sury (a matching release now
  exists — the original "no alpha.5 release, stay on alpha.2" note is obsolete).
  It emits `S.schema(s => …)` + `s.m(…)` — both still present in alpha.8.

## Phases

### Phase 0 — Hot-fix the production deploy (pin sury alpha.4)

**Goal:** restore working deploys today, with zero behaviour change. This
buys the runway for the proper migration.

Steps:
1. In `reventless/{aws,core,infra,spec}/package.json`, change
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
- **(Confirmed for alpha.8 by the spike.)** `decodeOrThrow` / `parseOrThrow`
  with labeled `~from` / `~to` are present in alpha.8's `S.resi` — the shim below
  uses exactly this form (encode via `decodeOrThrow(~from=schema, ~to=S.json)`).
  Call sites read `value->Util_Sury.toJson(schema)`.
- `S.t.Object` lost its `items: array<{name, location, schema}>` record in
  alpha.5 — only `properties: dict<t<unknown>>` remains (unchanged in alpha.8).
  `DcbDecode.res` and
  `DcbTag.res` walk variant schemas via
  `Object({items}).find(item => item.location == "TAG")` to identify the
  discriminant; that introspection has to be rewritten to
  `Object({properties}).Dict.get("TAG")` (sury-ppx still emits the discriminant
  under the `"TAG"` key; the `items` / `location` concepts are gone). This
  rewrite was not in the original plan — see Step 4 below.

Steps:

1. Add `reventless/spec/src/util/Util_Sury.res` (alpha.8 — spike-verified):
   ```rescript
   let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
     value->S.decodeOrThrow(~from=schema, ~to=S.json)
   let toJsonString: ('a, S.t<'a>, ~space: int) => string = (value, schema, ~space) =>
     value->S.decodeOrThrow(~from=schema, ~to=S.jsonStringWithSpace(space))
   let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) =>
     json->S.parseOrThrow(~to=schema)
   let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
     str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)
   ```
   (These four exactly match the standalone spike that compiled + round-tripped
   on `sury@alpha.8` + `sury-ppx@alpha.8`.)
   (Function-name shapes are kept alpha.4-compatible — `value->Util_Sury.toJson(schema)`
   matches `value->S.reverseConvertToJsonOrThrow(schema)` at the call site —
   so the subsequent bulk replace stays mechanical, even though the inside of
   the shim now uses labeled args.)
2. In a feature branch, locally bump `"sury": "11.0.0-alpha.4"` →
   `"11.0.0-alpha.8"` (and `sury-ppx` → `"11.0.0-alpha.8"`) in all 9 framework +
   adapter packages **and** run `pnpm install` to refresh the lockfile. (The Phase 0 audit
   already established 9 packages — `reventless-{spec,infra,interop,core,
   local,gwt,codegen,aws}` + `rescript-pulumi-aws` — not the 4 the
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
   local) via scripted s/old/new on the call-site forms (`S.parseJsonOrThrow`
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
2. Update `reventless/aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs`
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
paths into module-init-time `S.parser(~to=schema)` closures, so each Lambda
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
let parseEvent = S.parser(~to=Spec.eventSchema)
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

### Phase 4 — Flip to sury alpha.8 + republish Layer

**Goal:** remove the Phase-0 pin and ship a Layer carrying the
alpha.8-compatible framework.

Steps:
1. In `reventless/{aws,core,infra,spec}/package.json`, change
   `"sury": "11.0.0-alpha.4"` to `"sury": "11.0.0-alpha.8"` (and `sury-ppx` to
   `"11.0.0-alpha.8"`) — exact again; do not reintroduce `^` until alpha graduates.
2. `pnpm install`; confirm only `sury@11.0.0-alpha.8` resolves.
3. Full local build + test pass across reventless-core, reventless-local,
   reventless-aws, reventless-gwt, reventless-codegen, reventless-spec,
   reventless-interop, plus the example plugins.
4. Commit and push to `alpha`. CI publishes new alphas; the next Layer builds with
   `sury@11.0.0-alpha.8`; deploy workflow rolls Lambdas onto it.
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

- [x] Phase 0: production Lambdas no longer crash at init; `Platform_Plugins`
      query returns ≥ 1 edge with non-null `name`/`version`/`status`.
- [x] Phase 1: `Util_Sury` shim exists; `Message.res` + `Projection.res`
      ported; both core test suites green locally.
- [x] Phase 1: 2 new round-trip property tests for typed-state and
      variant-payload events.
- [x] Phase 2: files swept; zero `S.enableJson` / `js_nullable` /
      `reverseConvert*` / `parseJson*` / `convertOrThrow` remain in
      `--include="*.res"` (sury and lib excluded). `js_nullable` survives only
      as prose naming the `T | null` shape — no binding, no call site;
      `S.nullAsOption` replaced it.
- [x] Phase 2: per-package tests + zero compiler warnings.
- [ ] Phase 3: identified hot paths hoist parsers at module init — **not done.**
      No `S.parser(` hoist exists in the tree; every hot path still builds its
      parser per call through `Util_Sury.fromJson`. Deferred rather than
      abandoned: it is a self-contained performance change that needs no further
      sury work, so it can be picked up against rc.1 as it stands.
- [x] Phase 4: pin removed; all framework packages build + test on rc.1.
- [ ] Phase 4: Layer rebuilt and 30-minute log sweep clean — pending, both
      happen on the push to `alpha`.

## Risk register

| Risk                                                                                       | Likelihood | Impact | Mitigation                                                                       |
| ------------------------------------------------------------------------------------------ | ---------- | ------ | -------------------------------------------------------------------------------- |
| Behaviour divergence in `S.decodeOrThrow(~from=s, ~to=S.json)` vs `reverseConvertToJsonOrThrow` under `S.transform` / refinements | medium     | high   | Phase 1 round-trip property tests catch it before bulk migration                |
| sury-ppx alpha.8 + sury alpha.8 emit incompatible code (matched versions now exist)        | low        | high   | Phase 1 runs the full test suite on alpha.8 with a real PPX-using surface       |
| `S.nullAsOption` does not fully replace `js_nullable` in union variants (jsonableValidation regression returns) | low        | medium | Phase 2 step 3 explicitly re-tests `apiSchemaFragment`-style union variants     |
| Layer 60 build picks up another transitively-bumped library that breaks                    | low        | medium | Phase 4 verifies the locally-resolved tree before push; rollback to Layer 59     |
| `S.isoDateTime` rejects a timestamp shape we currently emit                                | low        | low    | Phase 2 step 5 audits `nowAsISOString` callers before flipping                  |

## Deferred follow-ups (own backlog items)

These came out of the analysis but are too large to bundle into the
migration sweep. They become materially easier once Phase 4 lands.

1. **Opportunity C — event schema versioning via `S.decoder` / `S.to` chains.**
   Plan (written): `docs/plans/Backlog/sury-event-schema-versioning.md`.
   Background:
   `docs/plans/done/effect-library-integration.md` §10,
   `docs/analysis/event-format-and-meta-review.md` #9.

2. **Opportunity F — type-driven GraphQL SDL via `S.toJSONSchema`.**
   Plan (written): `docs/plans/Backlog/typed-graphql-sdl-from-sury.md`; threads
   into the existing `docs/plans/Backlog/api-component-openapi.md`
   plan; both providers can consume the same converter. Will need a
   prerequisite review of `QueryDbResolvers_GraphQL.res` /
   `CommandGeneratorResolvers_GraphQL.res` to identify the swap surface.
   Background: `docs/analysis/rejected/sury-vs-effect-schema.md` §6.1.

3. **Opportunity G — Standard Schema v1 TypeScript SDK.**
   Threads into `docs/analysis/typescript-client-feasibility.md` Blocker 1
   resolution. Plan (written): `docs/plans/Backlog/typescript-client-sdk.md`.

4. **Opportunity B — hoist parsers on hot paths (Phase 3, unexecuted).**
   The migration landed without it: every hot path still builds its parser per
   call through `Util_Sury.fromJson`, and no `S.parser(` hoist exists in the
   tree. Phase 3 above already names the six target paths and the before/after
   shape, so it is directly actionable against rc.1 — it needs no further sury
   work, which is why it was dropped from the sweep rather than blocked by it.

## References

- Analysis: `docs/analysis/done/sury-11-migration.md`
- Sury repo: <https://github.com/DZakh/sury>
- Standard Schema: <https://standardschema.dev/>
- Related: `docs/plans/done/api-component-graphql.md`,
  `docs/plans/done/effect-library-integration.md`,
  `docs/analysis/event-format-and-meta-review.md`,
  `docs/analysis/typescript-client-feasibility.md`,
  `docs/analysis/given-when-then-specifications.md`,
  `docs/plans/Backlog/api-component-openapi.md`.
