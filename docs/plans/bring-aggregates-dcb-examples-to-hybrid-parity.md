# Plan: Bring `online-shop-aggregates` and `online-shop-dcb` to Full Parity with `online-shop-hybrid`

## Why

`examples/online-shop-hybrid/` has been the de-facto reference example for months — all docs, AutoUI/E2E plans, host-shell wiring, AWS deploy, and dev-tooling work have landed there. `examples/online-shop-aggregates/` and `examples/online-shop-dcb/` have not kept pace and now demonstrate an older surface of the framework. New users picking either of the single-style examples see:

- No README or onboarding instructions.
- No AWS deploy story (no `*-aws/` packages, no `deploy-manifest.yaml`, no Pulumi stacks).
- No host-shell local dev (no `serve`/`dev:full` scripts, no seeded `users.yaml`, no sqlite backend).
- Older pre-OutboundTranslationSlice patterns (`SideEffect/` + `Task/OrderNotifications` in aggregates).
- Missing example coverage of common framework features (Tasks, multi-source projections, cross-slice Flow tests, Extension/ExtensionPoint GWTs, per-command authorization).

This plan brings both to full structural and pattern parity with hybrid — while preserving each example's single-style identity (aggregates stays aggregate-only; DCB stays DCB-only).

> **Out of scope:** turning aggregates or DCB into hybrids. The mixed-style content unique to hybrid (`CatalogActivity` multi-source projection feeding both an Aggregate and a DCB source, hybrid plugin composition) remains hybrid-only. Each example demonstrates its style cleanly.

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

### 2.1 Replace the old `SideEffect/` + `Task/OrderNotifications` pattern with `OutboundTranslationSlice`

Currently:
- `ordering/src/Order/SideEffect/Order_EmailNotification.res`
- `ordering/src/Task/OrderNotifications.res` — wires the SideEffect

This is the pre-OutboundTranslationSlice pattern and conflicts with current framework guidance (PPX has `@@reventless.translation`, and OutboundTranslationSlice is the canonical egress mechanism).

Actions:
- Delete `Order/SideEffect/Order_EmailNotification.res`.
- Delete `Task/OrderNotifications.res`.
- Create `ordering/src/Order/OutboundTranslationSlice/SendOrderConfirmation/`:
  - `SendOrderConfirmation.res` — `@@reventless.spec` with `collect` matching the Order placed event.
  - `SendOrderConfirmation_Translation.res` — `@@reventless.translation` with async `translate` calling `EmailService` and returning `Result<option<unit>, string>`.
- Adapt the existing GWT (`Order_EmailNotification_GWT.res` or equivalent) into `SendOrderConfirmation_GWT.res`.
- Update `ordering/src/Plugin.res` will regenerate via the prebuild hook; no manual edit needed.

> **Note:** the aggregate-style example *does* use OutboundTranslationSlice here — the slice still applies on top of an Aggregate-driven plugin; OutboundTranslationSlice is style-neutral. This change is correctly within style purity.

### 2.2 Add `Refund` command to Order

Hybrid has 5 Order commands (Place/Cancel/Ship/Refund + one more); aggregates currently has 4 (no Refund).

- Extend `ordering/src/Order/Order.res` with a `Refund` constructor on `command`, a `Refunded` event, error variant, behavior implementation.
- Add a `Refund_GWT.res` test mirroring the others.
- Update behavior in `Order_Behavior.res`.

### 2.3 Add cross-plugin Flow test

- Create `platform-local/tests/Flow/AggregatesFlow_GWT.res` exercising Customer → Place Order → Ship Order → side-effect translation. Use the multi-spec `@@reventless.gwt` form already documented in conventions.

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
| 2.1 OutboundTranslationSlice migration | ~1.5h | — | Touches 3+ files, needs test rewrite |
| 2.2 Refund command | ~45 min | — | |
| 2.3 Flow test | ~1h | — | |
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
  - `feat(examples/aggregates): replace SideEffect with OutboundTranslationSlice`
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
