# Plan: Bring `online-shop-aggregates` and `online-shop-dcb` to Full Parity with `online-shop-hybrid`

## Why

`examples/online-shop-hybrid/` has been the de-facto reference example for months — all docs, AutoUI/E2E plans, host-shell wiring, AWS deploy, and dev-tooling work have landed there. `examples/online-shop-aggregates/` and `examples/online-shop-dcb/` have not kept pace and now demonstrate an older surface of the framework. New users picking either of the single-style examples see:

- No README or onboarding instructions.
- No AWS deploy story (no `*-aws/` packages, no `deploy-manifest.yaml`, no Pulumi stacks).
- No host-shell local dev (no `serve`/`dev:full` scripts, no seeded `users.yaml`, no sqlite backend).
- Missing GWT coverage for the existing `SideEffect/` + `Task/OrderNotifications` egress (note: framework gap — no `SideEffect_GWT` helper exists yet).
- Missing example coverage of common framework features (Tasks, multi-source projections, cross-slice Flow tests, Extension/ExtensionPoint GWTs, per-command authorization).

This plan brings both to full structural and pattern parity with hybrid — while preserving each example's single-style identity (aggregates stays aggregate-only; DCB stays DCB-only).

> **Out of scope:** turning aggregates or DCB into hybrids. The mixed-style content unique to hybrid (`CatalogActivity` multi-source projection feeding both an Aggregate and a DCB source, hybrid plugin composition) remains hybrid-only. Each example demonstrates its style cleanly.

## Style-purity audit (added mid-execution; both gaps now closed)

When work on Section 2 began, two of the originally-planned aggregate-side
steps were caught violating single-style purity — they prescribed DCB-only
framework features for the aggregate example. Both gaps have since been
closed by dedicated framework plans; the corresponding Section 2 steps are
now marked DONE below.

| Step | Original ask | Original blocker | Resolution |
|---|---|---|---|
| 2.1 | Replace `SideEffect/` + `Task/OrderNotifications` with `OutboundTranslationSlice` | `OutboundTranslationSlice_Builder` is hardwired to a DCB event log; aggregate per-aggregate EventTopics never reach it. There is no aggregate-side OTS variant. `SideEffect.T` (`reventless-spec/src/types/SideEffect.res`) is the canonical aggregate egress and stays. Test-side gap: no `SideEffect_GWT`. | [docs/plans/done/sideeffect-gwt.md](done/sideeffect-gwt.md) shipped `SideEffect_GWT` plus the per-service mock convention; the example wires `Order_EmailNotification_GWT` against `EmailService_Mock`. |
| 2.3 | Cross-plugin Flow test (`platform-local/tests/Flow/AggregatesFlow_GWT.res`) | `Flow_GWT.CommandStep` takes `Behavior_GWT.BehaviorSpec` — the DCB slice shape with `consumedEvent`. Aggregate specs don't expose `consumedEvent`, and Flow_GWT had no `AggregateCommandStep`. | [docs/plans/done/flow-gwt-aggregate-step.md](done/flow-gwt-aggregate-step.md) shipped `Flow_GWT.AggregateCommandStep` + `logEntry.aggregateId`; this plan's resumption pass added the `lastAggregateId` plumbing through `ExtensionPointStep` so aggregate-side EP mappings receive the real source ID. |

The remaining Section 2 steps (2.2, 2.4, 2.5, 2.6) and all of Section 3 are
style-pure as written:

- 2.2 Refund command on Order aggregate — aggregate-style.
- 2.4 EP/Extension GWTs — `Mapping_GWT` is style-neutral; the only adjustment is `module Delegate = <Aggregate>` instead of a DCB source module.
- 2.5 `@authorize` on a Category aggregate command — hybrid already applies the same annotation to its Category aggregate, so the pattern is style-portable.
- 2.6 Comment drift fix — trivial.
- 3.1 Task — `Task` is style-neutral (hybrid catalog has one too); driving it into an `InboundTranslationSlice` is DCB-native here.
- 3.2 Multi-source ReadModel projection — `ReadModel` is style-neutral; sources are all DCB StateChangeSlice events, so the example stays DCB-only.
- 3.3 `@@reventless.visibility(Internal)` on a StateViewSlice — style-neutral annotation on a DCB-native slice.
- 3.4 `@authorize` on a StateChangeSlice command — DCB-native.
- 3.5 Cross-plugin Flow test in DCB — Flow_GWT's native style.
- 3.6 EP/Extension GWTs — style-neutral, same as 2.4.
- 3.7 `@displayName` — style-neutral annotation.

### Resumption history

1. [sideeffect-gwt.md](done/sideeffect-gwt.md) landed → unblocked Step 2.1.
2. [flow-gwt-aggregate-step.md](done/flow-gwt-aggregate-step.md) landed →
   unblocked Step 2.3.
3. This plan was re-opened from `docs/plans/done/`, Steps 2.1 + 2.3 were
   executed, and the plan moved back to `done/`. The cross-plugin pass
   also required threading `lastAggregateId` through `ExtensionPointStep`
   — a small follow-up to the flow-aggregate-step plan, captured in the
   audit table above.

## Gap Summary

Baseline file counts (source `.res`, hand-written GWTs):

| Package | hybrid | aggregates | dcb |
|---|---:|---:|---:|
| catalog src | 26 | 16 | 27 |
| ordering src | 26 | 19 | 30 |
| catalog tests | 13 | 6 | 12 |
| ordering tests | 14 | 7 | 13 |
| platform-local tests | 1 | 0 | 0 |

Top-level assets missing from both stale examples:

- `README.md`
- `deploy-manifest.yaml`
- `scripts/find-orphans.py`
- `catalog-aws/`, `ordering-aws/`, `platform-aws/` packages (Pulumi `{yaml,alpha,beta,main}.yaml` stacks, generated `Plugin.res` + hand-written `Main.res`)
- `platform-local/users.example.yaml` (seeded `admin/admin`, `user/user` dev credentials)
- `platform-local/__mocks__/emptyModule.js` (Jest mock for `@npmcli/arborist`)
- Modern `platform-local/package.json` scripts: `serve`, `serve:memory`, `serve:reset`, `serve:watch`, `dev:full`, `dev:full:memory`, `dev:full:reset`, `dev:ui`
- `optionalDependencies: @reventlessdev/reventless-host-shell` on `platform-local`

---

## Step 1 — Universal Tooling & Top-Level Assets

Applies identically to both `online-shop-aggregates/` and `online-shop-dcb/`.

### 1.1 Top-level files

For each example, add:

- `README.md` — adapt hybrid's `README.md` to call out that this example shows the *aggregate-only* (resp. *DCB-only*) style. Same `pnpm run setup` / `serve` / `dev:full` flow. Same login instructions. Add a one-paragraph callout explaining "for the mixed-style example, see `online-shop-hybrid/`".
- `deploy-manifest.yaml` — copy hybrid's manifest verbatim, swap project name, swap plugin paths to point at the local `catalog`/`ordering` packages and the local `platform-aws`. Keep `region: eu-west-1`.
- `scripts/find-orphans.py` — copy verbatim from hybrid (it parameterizes off project name).
- `lib/` — create empty placeholder (matches hybrid).

### 1.2 platform-local modernization

For each example's `platform-local/`:

- **package.json** — port hybrid's full script block (`serve`, `serve:memory`, `serve:reset`, `serve:watch`, `dev:full`, `dev:full:memory`, `dev:full:reset`, `dev:ui`, Jest config block). Add `optionalDependencies: @reventlessdev/reventless-host-shell@<latest-tagged-version-from-ui-repo>` — read the live version per the user's [feedback_ui_versions_from_tags] memory; do not hand-bump.
- **`users.example.yaml`** — copy hybrid's verbatim (`admin/admin` + `user/user`). Same gitignore for the runtime `users.yaml` copy.
- **`__mocks__/emptyModule.js`** — copy verbatim.
- **`.gitignore`** — match hybrid's coverage of `.reventless/`, `users.yaml`, `lib/`, `__generated__/`, etc.
- **`tsx watch` whitelist** — hybrid's `serve:watch` script uses `--include` to scope watch paths to source roots. Adapt for each example's package layout (paths differ since the example folder names are different).

### 1.3 AWS packages

For each example, create three new packages mirroring hybrid:

#### `catalog-aws/`
- `package.json` — copy hybrid's; rename `name` to match the example (e.g. `@reventlessdev/online-shop-aggregates-catalog-aws`).
- `Pulumi.yaml`, `Pulumi.alpha.yaml`, `Pulumi.beta.yaml`, `Pulumi.main.yaml` — copy hybrid's; swap project name; swap stack-config names.
- `rescript.json` — copy hybrid's; swap package name and dependency reference.
- `src/Main.res` — copy hybrid's catalog-aws Main.res verbatim — it's just `CatalogPlugin.Plugin.Make(Platform)` with AWS adapters.
- `prebuild` script invokes `generate-plugin --aws CatalogPlugin ../catalog/src/`.

#### `ordering-aws/`
- Same recipe with Ordering.

#### `platform-aws/`
- `package.json` — copy hybrid's; rename.
- `Pulumi.{yaml,alpha,beta,main}.yaml` — copy hybrid's; swap project name; swap stack-config names. **Critical**: per the user's [reference_live_update_deploy_topology] memory, the host-shell pin is exact and needs manual bump; record the current pinned version in `Pulumi.yaml`.
- `src/Main.res` — copy hybrid's; the file does Cognito user-pool resolution, mounts the host-shell SPA via `Util_Bundle.resolvePackageRoot`, and launches `ReventlessAws.Platform.Make()`. Adapt only the plugin-namespace references.
- `verify-subscriptions.mjs` — copy verbatim.

> **Risk callout:** AWS packages are deploy-time only — no test will catch a typo until someone runs `pulumi up`. Validate by running `rescript build` at the root after creation, and (optionally — manual user step) a `pulumi preview` against the alpha stack.

### 1.4 Root rescript.json

Append the three new `*-aws/` packages from each example to the root `rescript.json` `dependencies` array so the root ESM build picks them up.

---

## Step 2 — Pattern Parity Inside `online-shop-aggregates/`

The aggregate example stays aggregate-only. The work is replacing outdated patterns and filling missing demonstrations.

### 2.1 Add `SideEffect_GWT` coverage to `Order_EmailNotification` — DONE

Closed by the [sideeffect-gwt plan](done/sideeffect-gwt.md). The example
ships:

- Runtime files unchanged (`Order/SideEffect/Order_EmailNotification.res` +
  `Task/OrderNotifications.res` remain the canonical aggregate-style egress).
- `src/Service/EmailService.res` was switched to a ref-backed `backend` so
  tests can swap in a recording mock without changing the SE itself.
- `tests/Order/SideEffect/EmailService_Mock.res` records every call into a
  ref and exposes `mock: SideEffect_GWT.mock<call>` for the GWT.
- `tests/Order/SideEffect/Order_EmailNotification_GWT.res` covers `Placed`
  (triggers `SendOrderConfirmation`), `Shipped` (no-op), and `Cancelled`
  (no-op).

The mock module lives next to the GWT (`tests/Order/SideEffect/`) rather
than under `src/Service/` as originally sketched — `_Mock.res` belongs in
the test tree, not the publish surface.

### 2.2 Add `Refund` command to Order

Hybrid has 5 Order commands (Place/Cancel/Ship/Refund + one more); aggregates currently has 4 (no Refund).

- Extend `ordering/src/Order/Order.res` with a `Refund` constructor on `command`, a `Refunded` event, error variant, behavior implementation.
- Add a `Refund_GWT.res` test mirroring the others.
- Update behavior in `Order_Behavior.res`.

### 2.3 Add cross-plugin Flow test — DONE

Closed by the [flow-gwt-aggregate-step plan](done/flow-gwt-aggregate-step.md)
plus a small follow-up to `ExtensionPointStep`. The example ships
`platform-local/tests/Flow/AggregatesFlow_GWT.res` covering two describes:

- **Single-plugin** sweeps inside Ordering: `CatalogProduct sync → Order.Place
  → Order.Ship`, `~id` isolation, error paths, and `givenEvents` seeding.
- **Cross-plugin** sweeps: `Catalog.Product.Add → Products_ExtensionPoint
  → Products_Extension → Ordering.CatalogProduct.Sync`, and the return
  trip `Ordering.Order.Place → Orders_ExtensionPoint (fan-out) →
  Orders_Extension → Catalog.ProductDemand.Record`.

Required one new piece of framework plumbing: `flowState.lastAggregateId`
threads the producing aggregate's ID into `ExtensionPointStep` so the EP
mapping's `mapOutgoingEvent(id, ...)` receives the real aggregate-ID
instead of the previous hard-coded `"gwt-id"` literal. DCB upstreams leave
the field `None` and the EP step falls back to the literal — the existing
hybrid + DCB Flow tests still pass unchanged.

The SideEffect tail (`Order_EmailNotification`) is not part of the flow:
`SideEffect_GWT` exists as a per-component DSL but there is no
`Flow_GWT.SideEffectStep` yet, and the SE is already covered in isolation
by `Order_EmailNotification_GWT`. Adding a flow step kind for it is a
separate follow-up if a real cross-plugin flow ever needs to assert on
SE-fired calls.

### 2.4 Add ExtensionPoint/Extension GWTs

Currently aggregates has no `tests/Extension/` or `tests/ExtensionPoint/` folders.

- `catalog/tests/ExtensionPoint/Products_ExtensionPointMapping_GWT.res`
- `ordering/tests/Extension/Orders_Extension_GWT.res`

Use hybrid's versions as templates; adapt the `Delegate` references — aggregates uses `module Delegate = CatalogProduct` (real aggregate) rather than the DCB-style delegate.

### 2.5 Add `@authorize` example

Pick one command to annotate with `@authorize(AllowGroups(["Admin"]))` — mirror hybrid's choice of `Category.Archive`. Update the matching `_GWT` test to drive it under both privileged and unprivileged identity.

### 2.6 Fix the catalog-spec comment drift

`catalog-spec/src/Products_ExtensionPoint.res` line 1 currently says `// ProductsExtensionPoint spec — stable public API from Catalog`. Change to `// Products_ExtensionPoint spec — stable public API from Catalog to Ordering.` to match hybrid/dcb.

---

## Step 3 — Pattern Parity Inside `online-shop-dcb/`

The DCB example stays DCB-only. Fill missing capability demonstrations.

### 3.1 Add a Task example

DCB has zero `Task/`. Add `catalog/src/Task/ImportProducts.res` — port hybrid's stub (or adapt aggregates' fuller S3 → command Task implementation, modernized to use current PPX). The Task drives an InboundTranslationSlice command rather than an aggregate.

### 3.2 Add multi-source ReadModel projection

DCB has zero `@@reventless.mappings` files. Add a multi-source projection so the example demonstrates how a single read model can ingest from multiple DCB sources.

- Create `catalog/src/CategoryActivity/ReadModel/CategoryActivity.res` (spec) + `CategoryActivity_Projections.res` (`@@reventless.mappings`) feeding from `Category` StateChangeSlice events.
- This mirrors hybrid's `CatalogActivity` ReadModel but uses only DCB sources (not Aggregate + DCB).
- Add `_GWT.res` covering the multi-source mappings.

### 3.3 Add `@@reventless.visibility(Internal)` example

Annotate `ordering/src/CatalogProduct/StateViewSlice/AvailableProducts/AvailableProducts.res` with `@@reventless.visibility(Internal)` to match hybrid's intent (this view exists to support Order placement and isn't shown in AutoUI panels).

### 3.4 Add `@authorize` example

Same as 2.5 — annotate one StateChangeSlice command (e.g. `Category.ArchiveCategory`) with `@authorize(AllowGroups(["Admin"]))` + matching GWT update.

### 3.5 Add cross-plugin Flow test

- `platform-local/tests/Flow/DcbFlow_GWT.res` — exercise Register Customer → Place Order → AutoShip → SendOrderConfirmation.

### 3.6 Add ExtensionPoint/Extension GWTs

- `catalog/tests/ExtensionPoint/Products_ExtensionPointMapping_GWT.res`
- `ordering/tests/Extension/Orders_Extension_GWT.res`

The DCB-style `Delegate` already matches hybrid (uses `let name = "CatalogDcbEventLog"; @schema type event = ...`), so these can be near-verbatim copies of hybrid's.

### 3.7 Add `@displayName` example

Annotate the `email` field on Customer in DCB to match hybrid's `@displayName` usage. Currently DCB lacks this PPX annotation entirely.

---

## Step 4 — Verification

For each example, after Steps 1–3:

1. **Build**: `pnpm install && pnpm run build` at the example's root scope. Zero warnings (per `.claude/rules/conventions.md`).
2. **Tests**: `pnpm test` from each package. New Flow tests, EP/Extension GWTs, and the new slice GWTs must pass.
3. **Local serve**: `pnpm --filter ./examples/online-shop-aggregates/platform-local serve:memory` boots cleanly. Login flow works with seeded users.yaml.
4. **Generate**: `generate-plugin src/` regenerates `Plugin.res` without diff (idempotent) for catalog and ordering in each example.
5. **(Manual, user step)** `pulumi preview` against the alpha stack for one of the new AWS packages to confirm Pulumi configs are well-formed.

---

## Step 5 — Documentation Side-Effects

After parity lands, update:

- `docs/guides/platform-and-plugin-guide.md` — if any wording calls out hybrid as the only multi-style demo or as the unique source of certain examples, broaden the language to acknowledge aggregates/DCB as the single-style equivalents.
- Any AutoUI / AWS deploy plans in `docs/plans/done/` that reference `examples/online-shop-hybrid/` by hardcoded path — check whether they need a callout that the same approach now applies to all three examples.

---

## Sequencing & Effort Estimate

| Step | Aggregates | DCB | Notes |
|---|---|---|---|
| 1.1 README + deploy-manifest + scripts | ~30 min | ~30 min | Mostly copy-paste with sed |
| 1.2 platform-local modernization | ~45 min | ~45 min | Includes users.yaml + scripts + mock |
| 1.3 AWS packages (3 each) | ~2h | ~2h | Risk: Pulumi config typos |
| 2.1 SideEffect_GWT coverage | ~45 min (resumed) | — | shipped after sideeffect-gwt landed |
| 2.2 Refund command | ~45 min | — | |
| 2.3 Cross-plugin Flow test | ~1h (resumed) | — | shipped after flow-gwt-aggregate-step landed + lastAggregateId follow-up |
| 2.4 EP/Extension GWTs | ~45 min | — | |
| 2.5 @authorize | ~30 min | — | |
| 2.6 comment drift | ~5 min | — | |
| 3.1 Task example | — | ~1h | |
| 3.2 Multi-source projection | — | ~1.5h | |
| 3.3 @@reventless.visibility | — | ~15 min | |
| 3.4 @authorize | — | ~30 min | |
| 3.5 Flow test | — | ~1h | |
| 3.6 EP/Extension GWTs | — | ~45 min | |
| 3.7 @displayName | — | ~15 min | |
| 4 Verification | ~1h | ~1h | |
| **Total** | **~9h** | **~10h** | Best done as separate sessions; commit after each step |

## Suggested Branch & Commit Plan

- Single branch for both examples: `examples/parity-with-hybrid`.
- Commit per step (so a step can be reverted independently if it surfaces problems).
- Commit message style:
  - `chore(examples/aggregates): port platform-local dev scripts + users.yaml`
  - `feat(examples/dcb): add multi-source CategoryActivity ReadModel projection`
  - `chore(examples/aggregates): add AWS packages (catalog-aws, ordering-aws, platform-aws)`
- Per the user's commit-confirmation memory, surface each commit message before running `git commit`.

## Risks & Open Questions

1. **AWS package validation** — without a `pulumi preview` run, typos in Pulumi configs aren't caught at build time. Either the user runs a preview after each AWS package is added, or we accept that the first deploy attempt will be the discovery point.
2. **Host-shell version pinning** — per [reference_live_update_deploy_topology] and [feedback_ui_versions_from_tags], the host-shell pin must come from the latest git tag in the UI repo, not be hand-bumped. Confirm the current pinned version in hybrid's `platform-aws/Pulumi.yaml` and reuse exactly.
3. **Style purity** — the plan deliberately keeps each example single-style. If during execution we discover a missing pattern that *requires* mixing styles to demonstrate (e.g. multi-source projection across Aggregate + DCB sources), we accept that gap and leave it as hybrid-exclusive content.
4. **Lerna version alignment** — current versions are `hybrid@1.0.0-alpha.83`, `aggregates@3.0.0-alpha.85`, `dcb@1.0.0-alpha.88`. After this work the three examples will diverge less; verify that semantic-release's per-example versioning doesn't cause weirdness (publish-private should mean the version numbers are cosmetic).
5. **Memory hooks** — when this plan lands, update the auto-memory entries that currently treat hybrid as the canonical "live-update deploy topology" example — both new examples will have the same CI deploy topology after Step 1.3.

## Done Criteria

- All commands in CLAUDE.md's per-package "Build Commands" section work cleanly from any of the three example roots.
- Each example serves locally via `serve:memory` and `dev:full` with login working.
- Pattern coverage (slices, EP, Extension, Translation, Task, Automation, multi-source projection, authorization, visibility, displayName) is documented in a small comparison table inside each README's footer so the equivalence is visible to new users.
- Plan moved to `docs/plans/done/` as part of the final commit.
