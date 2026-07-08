# Deploy-time admin-base schema clobber of the split-mode DomainApi

Scope: stop `preAdminResolversSchemaHook` from pushing the admin-base-only SDL
onto the **DomainApi** in split-API mode, and make the deploy-time repair
field-identity-aware so a clobbered DomainApi reliably heals on the next plugin
deploy.

Status: **implemented (A + B + C)** on `alpha`. Local build clean (zero
warnings); reventless-core (499) and reventless-aws (204) suites green,
`GraphQL_StitcherTest` extended to 18 cases (set-diff, equal-count swap, additive
push, Subscription-inclusive shrink). **Alpha deploy verification still pending**
— keep this plan here until the split-mode redeploy checks below pass, then move
to `docs/plans/done/`.

Sibling of
[`appsync-runtime-schema-clobber-hardening.md`](appsync-runtime-schema-clobber-hardening.md),
which hardened the **runtime** (`mkUpdateApiSchema`) clobber path and added a
count-based deploy-time repair. That work did **not** cover the deploy-time
admin-target fallback described here, and its guards were cardinality-based (see
"Guard gap" below); this plan makes them identity-based. The admin-base-only
DomainApi state it set out to prevent **recurred on alpha (2026-07-08)** — same
fingerprint, different cause.

## Problem

In split-API mode the admin schema belongs on the **PlatformApi**; the
**DomainApi** carries plugin fields only (the plugin `Api` uses
`emptyBaseFragment`, `Platform.res`). `preAdminResolversSchemaHook` builds an
**admin-base-only** SDL — it stitches `AdminApi.baseFragment` with an *empty*
plugin-fragment list — and pushes it to `targetApi`:

```rescript
let targetApi = switch splitApiOutputsRef.contents {
| Some({platformApi}) => platformApi
| None => domainApi          // ← fallback lands admin-base on the DomainApi
}
```

`startSchemaCreation` **replaces the entire schema**. So when `targetApi`
resolves to the DomainApi, the admin-base push wipes every plugin field, leaving
exactly the admin-base fields. Plugin resolver creation then fails:

```
No field named Ordering_Customer_UpdateAddress found on type Mutation
No field named onOrdering_Customer_Register found on type Subscription
```

The plugin fragments in `PluginSchemaPersistence` (`deploy-schema:<Plugin>`) stay
intact — only the live schema is clobbered.

### Evidence (alpha, 2026-07-08)

- DomainApi `Mutation`/`Query`/`Subscription` held **only** the 7-field
  `AdminApi.baseFragment` set (`Platform_Plugin_Activate`, `Platform_UIFragment*`,
  …) — zero `Ordering_*`/`Catalog_*`. That is the exact output of
  `stitch(adminBase, [])`, i.e. `preAdminResolversSchemaHook`, not the runtime
  path (which stitches `adminBase + plugin fragments`).
- `PluginSchemaPersistence:deploy-schema:Ordering` still carried all four
  `Customer` commands (`Register`, `UpdateEmail`, `UpdateAddress`, `Deactivate`);
  `deploy-schema:Catalog` intact too. Data sources fine; live schema wrong.
- The PlatformApi held the correct full admin set (60 fields). Only the DomainApi
  was clobbered.
- The runtime collector's re-stitch pushed `adminBase + 2 fragments` to a
  *different* (older) API, so the runtime hardening was working as intended and
  is not the cause here.

## Guard gap (why the existing repair didn't save it)

The deploy-time repair added in the sibling plan re-pushes when the live schema
has drifted, but it compares **root-field counts**, not field-name **sets**:

- `preResolversSchemaHook` skip check: repair only when
  `countRoots(live) < countRoots(expected)`. A clobber whose live count is `≥`
  expected (a field *swap*, or extra unrelated fields) evades repair.
- `GraphQL_Stitcher.isCatastrophicSchemaShrink` counts **Mutation + Query only**
  — it ignores `Subscription` entirely — and only trips below a 50% shrink.

So even once the admin-base clobber happens, the next plugin deploy's repair can
be skipped, and a later platform redeploy re-clobbers. The count heuristics need
to become identity checks.

## Fixes

**A — Admin-base push must never target the DomainApi in split mode.**
When `Config.splitApi` is true and `splitApiOutputsRef.contents` is `None` at
hook time, do **not** fall back to `domainApi`. Instead resolve the platform API
deterministically. Options, in preference order:
1. Sequence the hook behind `splitApiOutputsRef` population — the hook already
   documents that `makePlatform`/`deployPlatform` populate the ref "before
   Admin.construct fires"; make that a hard dependency (await/`Output` on the
   ref) rather than a best-effort read with a domain fallback.
2. Thread the platform API into the hook closure explicitly at construction, so
   there is no late `ref` read to miss.
3. As a last-resort guard: if split mode and the platform API is genuinely
   unavailable, **skip** the admin push (log loudly) rather than clobber the
   DomainApi. Never push an admin-base-only SDL to the DomainApi.

**B — Identity-aware deploy-time repair.**
Add `GraphQL_Stitcher.rootTypeFieldNames(~sdl, ~typeName): array<string>`
(the set the existing `countRootTypeFields` only counts). In
`preResolversSchemaHook`, force a repair push whenever the live root field-name
**set** is not a superset of the expected set (any expected field missing),
instead of the `live_count < expected_count` test. This heals swaps and
equal-cardinality drift that the count test misses.

**C — Make the shrink guard set-based and include Subscription.**
`isCatastrophicSchemaShrink` should compare field-name sets across
`Mutation + Query + Subscription` and refuse a push only when it would drop
fields the pushing stack does not own — never when it is *adding* owned fields.
Fold this into the same `rootTypeFieldNames` helper so the runtime guard
(`AdminEventCollectorEntryPoint.mjs`) and both deploy-time guards share one
identity-based implementation.

## Implementation (as built)

- **A** — `preAdminResolversSchemaHook` (`reventless-aws/src/Platform.res`) now
  selects the target API as `switch (Config.splitApi, splitApiOutputsRef.contents)`:
  ref populated → `platformApi`; unified + `None` → `domainApi`; **split +
  `None` → skip** (log `error`, return `adminBarrier` unchanged so the admin
  barrier still gates `createResolvers`). The admin-base-only SDL can no longer
  reach the DomainApi. Chose option 3 (last-resort skip) over threading the
  platform API in at construction (option 2) because the PlatformApi is not yet
  constructed when the hook closure is built — the late `ref` read is
  structural; making the fallback *safe* is the minimal correct fix.
- **B** — added `GraphQL_Stitcher.rootTypeFieldNames(~sdl, ~typeName)`,
  `allRootFieldNames(~sdl)`, and `missingRootFields(~expectedSdl, ~liveSdl)`
  (`reventless-core`). The hash-match drift check in `preResolversSchemaHook`
  now forces a repair push whenever `missingRootFields` is non-empty — i.e. the
  live root field-name set is not a superset of the expected set — instead of
  the old `live_count < expected_count` test. Heals swaps and equal-cardinality
  drift.
- **C** — `isCatastrophicSchemaShrink` is now identity-based across
  **Mutation + Query + Subscription**: a push whose field-name set is a superset
  of the live set (purely additive / unchanged) is **never** rejected, even
  below the cardinality ratio; only a push that *drops* live fields falls back
  to the `threshold` check on the union of all three root types. Both
  deploy-time guards and the runtime guard
  (`AdminEventCollectorEntryPoint.mjs`, which imports the compiled function)
  share this one implementation.
  - *Deviation from the sketch:* the guard signature does not carry per-field
    ownership, so "drop fields the pushing stack does not own" is approximated
    by the additive-superset exemption (never block a stack adding its own
    fields) plus the threshold on genuine drops. This removes the common
    false-positive without threading ownership metadata; the count fallback
    still catches a catastrophic drop. `rootTypeFieldNames` strips a trailing
    `:` left on no-arg fields so `name` and `name(args)` compare equal.

## Verification

- Deploy a split-mode platform + ≥2 domain plugins; introspect the DomainApi and
  confirm it carries all plugin fields and **no** admin-base fields.
- Force the fallback window: run `preAdminResolversSchemaHook` with
  `splitApiOutputsRef = None` and assert it never issues a
  `StartSchemaCreation` against the DomainApi (fix A).
- Unit: `rootTypeFieldNames` set-difference; repair fires on an equal-count swap
  (fix B); shrink guard tolerates additive pushes and includes Subscription
  (fix C). ✅ done — `tests/api/GraphQL_StitcherTest.res` (18 cases).
- Redeploy the platform stack after a plugin deploy and confirm the DomainApi
  plugin fields survive (regression for the recurrence).

## Operational unblock (pre-fix)

The live schema can be repaired without any code change, because the plugin
fragments are intact in `PluginSchemaPersistence`:

- Re-push the stitched domain SDL (`emptyBase + deploy-schema:*` fragments)
  directly via `StartSchemaCreation` + wait-for-ACTIVE, reusing
  `GraphQL_Stitcher.stitch` / `AppSync_Adapter` so the SDL matches a real deploy.
  (A one-off script doing exactly this lives in the consuming repo; it is not
  core's concern, but the mechanism is: empty base + every `deploy-schema:` row.)
- Or delete the `deploy-schema-hash:<domainApiId>` row and redeploy the plugin
  stack alone — the drift-aware repair then re-pushes once.
- **Do not redeploy the platform stack** after healing until fix A lands, or the
  admin-base push re-clobbers the DomainApi.

## Out of scope

- The runtime `mkUpdateApiSchema` clobber (covered by the sibling plan).
- Unified (non-split) mode, where admin + plugins legitimately share one API and
  the admin base coexists with plugin fields.
