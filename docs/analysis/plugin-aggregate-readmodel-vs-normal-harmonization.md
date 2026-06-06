# Plugin Aggregate / ReadModel vs. Normal Aggregates / ReadModels — Divergence Analysis & Harmonization

**Status:** Analysis
**Date:** 2026-06-04
**Scope:** `reventless-core/src/admin/` (Platform_Admin, Plugin aggregate, Plugins read model) vs. the
generic component pipeline in `reventless-core/src/components/Plugin/`, plus the platform seeding paths in
`reventless-local/src/Platform.res` and `reventless-aws/.../Platform_UIDefinitions_Lambda.res`.

---

## 1. Motivating question

While reviewing how the Plugins UI decides which commands (`Activate` / `Deactivate`) to show per row, two
oddities surfaced:

1. The command-visibility-by-state metadata (`allowedStates`) for the Plugin aggregate is **hand-written** in
   [`Platform_Admin_Structure.res`](../../reventless/reventless-core/src/admin/Platform_Admin_Structure.res),
   not derived from `@allowedStates` annotations on the spec like every other aggregate.
2. The Plugin read model's GraphQL surface is **hand-rolled** in
   [`PluginBaseFragment.res`](../../reventless/reventless-core/src/admin/PluginBaseFragment.res) rather than
   generated from the spec.

This document explains *why* the Plugin aggregate/read model diverge from normal components, catalogs the
concrete differences, and proposes how the two paths could be harmonized.

---

## 2. The normal component pipeline (how an ordinary plugin works)

For a user plugin (`examples/online-shop-*`), the flow is fully automatic:

1. **Discovery / composition.** `generate-plugin` scans `src/` by folder name and emits the
   `Plugin.res` composition root, wiring every discovered aggregate / read model / slice.
2. **Structure extraction.** At build time, `Plugin_Builder.make` calls
   [`Plugin_Structure.make`](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res#L88)
   over the spec modules. This reads PPX-emitted metadata — including the per-variant `@allowedStates` (via
   [`ApiAllowedStatesHelpers`](../../reventless/reventless-core/src/components/Api/ApiAllowedStatesHelpers.res)),
   the `@status` field, `@displayName`, etc. — and produces a `pluginStructure` value
   (`commandDef[]`, `queryableDef[]`, …).
3. **Schema generation.** The GraphQL fragment (mutations + queries) is generated from the same spec schemas
   via `FragmentProvider.generateFragment`
   ([`Plugin_Builder.res:286`](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L286)).
4. **Self-delivery via Connect.** The computed `pluginStructure` rides into the platform inside the
   **Connect** command's `pluginDefinition.structure`
   ([`Plugin_Builder.res:622`](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L622),
   surfaced as `outputs.pluginStructure` at line 812).
5. **Projection.** [`PluginsProjection`](../../reventless/reventless-core/src/admin/PluginsProjection.res#L53-L73)
   stores `pluginDef.structure` into the Plugins read-model state.
6. **Seeding for AutoUI.** The platform copies each plugin's `outputs.pluginStructure` into
   `pluginStructuresStore`
   ([`seedPluginStructuresStore`](../../reventless/reventless-local/src/Platform.res#L898)), from which
   `Platform_UIDefinitions` serves the AutoUI manifest.

**Key property:** the spec is the single source of truth; structure + schema are *derived*, and the plugin
*ships its own metadata* into the platform through the registration handshake.

---

## 3. The Plugin aggregate / read model path (what's different)

The Plugin aggregate (`PluginSpec.res`) and Plugins read model (`PluginsReadModelSpec.res`) are part of
**`Platform_Admin`** — the platform's built-in management surface — and bypass several of the steps above.

### 3a. What is still shared (not special)

It's important not to overstate the divergence. The **write side runs through the generic machinery**:

- The Plugin aggregate is passed in via the `~aggregates` parameter of `Platform_Admin.construct`
  ([line 103](../../reventless/reventless-core/src/admin/Platform_Admin.res#L103)).
- Its CommandGenerator/resolver wiring uses the normal path via
  [`Plugin_Helpers.registerAdminAggregateMutations`](../../reventless/reventless-core/src/admin/Platform_Admin.res#L138).
- The mutation SDL **is** derived from `PluginSpec.command`:
  [`pluginAggregateMutationEntries`](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L75-L94)
  reads the variant names off the schema and filters `@noApi` — exactly like the generic path.

### 3b. What is hand-rolled

Two pieces are authored by hand:

**(1) Query schema surface** — [`PluginBaseFragment.queryEntries`](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L37-L62)
instead of auto-generation, because of bespoke shape/naming requirements (see §4).

**(2) `pluginStructure` (AutoUI metadata)** — [`Platform_Admin_Structure.res`](../../reventless/reventless-core/src/admin/Platform_Admin_Structure.res)
reconstructs by hand what `Plugin_Structure.make` would otherwise emit: `activateCommand` / `deactivateCommand`
with literal `allowedStates`, the `pluginReadModel` `queryableDef` with `statusField: Some("status")`, etc.
Its own header comment states the reason:

> The admin's Plugin aggregate + Plugin/PlatformEventGraph read models are wired into the GraphQL schema via
> PluginBaseFragment, not through the regular `~aggregates` / `~readModels` arrays … As a result,
> `Plugin_Structure.make` never sees them … This module produces an equivalent structure by hand.

### 3c. Manual seeding (the divergence's blast radius)

Because `Admin.construct` does not flow through `pluginStructure` outputs, the synthetic structure must be
**injected manually at platform startup — in three places**, each carrying a near-identical "Admin.construct
does not flow through pluginStructure outputs" comment:

| Location | What it seeds |
|---|---|
| [`Platform.res:1328`](../../reventless/reventless-local/src/Platform.res#L1328) | `pluginStructuresStore` admin entry |
| [`Platform.res:1043`](../../reventless/reventless-local/src/Platform.res#L1043) (`seedAdminPlatformEventGraphEntry`) | PlatformEventGraph admin row |
| [`Platform_UIDefinitions_Lambda.res:115`](../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L115) | AWS AutoUI manifest admin entry |

---

## 4. Why it diverges — three forces

### Force 1 — Bootstrapping (fundamental)

The Plugin aggregate **is the registry of plugins**. It exists before, and in order to process, any plugin
registration. A normal plugin *delivers* its structure through the **Connect** handshake; but there is no
Connect handshake for the platform itself. Internally the admin even fabricates a `fakePluginDefinition` with
`structure: None`
([`Platform_Admin.res:70-83`](../../reventless/reventless-core/src/admin/Platform_Admin.res#L70-L83)).

This is the chicken-and-egg: the component that *implements* plugin registration cannot itself arrive through
that pipeline. Hence the structure a real plugin would deliver must be synthesized by hand and seeded directly.
**This is the only inherent reason.**

### Force 2 — The admin schema is the *base* fragment, not a stitched plugin fragment

Plugin schemas are fragments stitched in at connect time; the admin's is `AdminApi.baseFragment` —
always-present and foundational, carrying platform policy: the `Platform_` field prefix
([`Api_Naming.adminField`](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L46)) and the
`Admin` authorization group ([`adminAuth`](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L3-L6)).
These are platform concerns, not per-plugin codegen output.

### Force 3 — Bespoke shape/naming mismatches

`PluginBaseFragment` is largely comments documenting special cases the generic codegen does not model:

- read-model `Spec.name` is **plural** `"Plugins"` but the GraphQL type is **singular** `Platform_Plugin`
  ([lines 39-48](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L39-L48));
- the explicit `Platform_UIFragments` field would **collide** with an auto-generated connection field
  ([lines 32-36](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L32-L36));
- `option<nested-object>` fields (`apiSchemaFragment`, `uiFragments`, `structure`) must be **excluded** or
  AutoUI renders them as scalar columns and every Plugin row fails to load
  ([lines 19-30](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L19-L30)).

Forces 2 and 3 are **incidental** — products of how the admin grew, not laws of the architecture.

---

## 5. Side-by-side comparison

| Concern | Normal aggregate / read model | Plugin aggregate / read model |
|---|---|---|
| Discovery | `generate-plugin` scans `src/` | Built into `Platform_Admin`; never discovered |
| `pluginStructure` source | Derived by `Plugin_Structure.make` from spec | Hand-written in `Platform_Admin_Structure.res` |
| `allowedStates` source | `@allowedStates` PPX annotation on command variants | Literal arrays in `commandDef`s |
| `statusField` source | `@status` annotation / `"status"` convention | Literal `Some("status")` |
| Command mutation SDL | Generated from command schema | Generated from command schema (**shared**) |
| Query SDL | Auto-generated | Hand-rolled `PluginBaseFragment.queryEntries` |
| Field naming | `uncapitalize(name)` / plural conventions | `Platform_`-prefixed via `Api_Naming.adminField` |
| Authorization | Per-spec `@index` group / default | Fixed `Admin` group (`adminAuth`) |
| Delivery to platform | Self-delivered via Connect `pluginDefinition.structure` | Seeded manually at startup (×3 sites) |
| Excluded fields | None (or per-annotation) | `pluginExcludeFields` / `pluginUIOnlyExcludeFields` |
| Drift risk | Low (single source of truth) | High (hand-written copies must track behavior + SDL) |

### Drift hazards observed

- `Platform_Admin_Structure.res` must keep `allowedStates` in sync with the accept/reject branches of
  `PluginBehavior` *by hand* (the file says so at
  [lines 65-68](../../reventless/reventless-core/src/admin/Platform_Admin_Structure.res#L65-L68)).
- Excluded-field lists are shared between `PluginBaseFragment` and `Platform_Admin_Structure` precisely because
  a mismatch makes AutoUI query non-existent fields and every row fails to load.
- The synthetic structure is seeded in three independent locations; adding a fourth consumer means a fourth
  manual seed.

---

## 6. Harmonization options

Ordered from highest-leverage / highest-risk to incremental.

### Option A — Platform self-registration (eliminates Force 1's symptom)

Give the platform a one-time "register myself" step that runs `Plugin_Structure.make` over the admin specs
(`PluginSpec`, `PluginsReadModelSpec`, `Platform_EventGraphReadModelSpec`) and seeds the result into
`pluginStructuresStore` — the same value a real plugin would deliver via Connect.

- **Removes:** `Platform_Admin_Structure.res` (the hand-written structure) and the three manual seed sites
  collapse into one derive-and-seed call.
- **Enables:** `@allowedStates` / `@status` annotations on `PluginSpec` / `PluginsReadModelSpec` become the
  source of truth — killing the `allowedStates`↔`PluginBehavior` drift hazard.
- **Risk:** bootstrapping order. The admin specs must be runnable through `Plugin_Structure.make` before the
  platform finishes constructing. Needs care that `Plugin_Structure.make` has no hidden dependency on the
  plugin having gone through Connect.
- **Caveat:** the *schema* surface (Force 3) is separate — see Option B.

### Option B — Make the generic schema generator absorb the admin's needs

Teach `FragmentProvider.generateFragment` (or its inputs) to express what `PluginBaseFragment` does by hand:

- a configurable field-name prefix (`Platform_`) and fixed authorization group;
- singular-type-name override when `Spec.name` is plural;
- field-exclusion list (reuse `@@reventless.visibility(Internal)` or a new field-level exclude annotation);
- a way to declare an explicit field (`Platform_UIFragments`) that suppresses the auto-generated collision.

If all four exist, `PluginBaseFragment.queryEntries` reduces to configuration, and the admin read model can be
generated like any other.

- **Risk:** these escape hatches would be used by ~one component today; weigh against the cost of carrying
  them in the generic path. Some (prefix, exclude, visibility) are plausibly useful to user plugins too.

### Option C — Single source of truth for exclusions + allowedStates (low-risk, do regardless)

Even without A or B:

1. Move `allowedStates` for `Activate` / `Deactivate` to `@allowedStates` annotations on `PluginSpec.command`
   and have `Platform_Admin_Structure` read them via `ApiAllowedStatesHelpers` instead of literals — removes
   the behavior-drift hazard immediately.
2. Collapse the three manual seed sites behind one helper (`Platform_Admin.seedAdminStructure(store)`) so a
   new consumer can't forget one.
3. Keep `pluginExcludeFields` already shared (it is) and add a compile-time assertion that the structure's
   read-model schema and the SDL exclude the same fields.

### Recommendation

- **Now:** Option C — pure cleanup, no bootstrapping risk, removes the worst drift hazards.
- **Next:** Option A — the real fix for Force 1; collapses `Platform_Admin_Structure.res` and unifies the
  metadata source of truth.
- **Later / optional:** Option B — only if the prefix/exclude/visibility escape hatches earn their keep for
  user plugins too; otherwise leave the hand-rolled query fragment as a documented, contained exception.

---

## 7. TL;DR

The Plugin aggregate/read model are not arbitrarily special: their **command write-side already runs through
the normal pipeline**. What diverges is (a) the `pluginStructure` metadata and (b) the query schema surface,
because the platform's own registry component cannot register *itself* through the plugin Connect handshake it
implements (Force 1, fundamental), and because the admin schema carries bespoke prefix/auth/naming/exclusion
policy (Forces 2–3, incidental). The cleanest harmonization is **platform self-registration** that derives the
admin structure from the specs (restoring single-source-of-truth and enabling `@allowedStates` annotations),
with an immediate low-risk win in consolidating the hand-written `allowedStates` and the triplicated seed
sites.
