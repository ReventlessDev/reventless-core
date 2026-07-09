# DCB StateChangeSlice per-command mutation naming — overflows AppSync 50-char subscription limit + renames the primary command (regression from `dcb-statechange-slice-per-command-mutations`)

**Status:** DONE — shipped the `${plugin}_${command}` naming + build-time 50-char
subscription guard (`Api_Naming.dcbCommandMutationField` / `assertSubscriptionNameFits`).
Single-command slices stay byte-identical; resolver dispatch (positional / trailing-segment)
unchanged. Tests updated + added (per-command shape, `on…` ≤ 50, build-time overflow
regression). Cross-slice collision disambiguation intentionally not implemented (command
names are unique per plugin; the length guard covers the deploy-blocker regardless).

Follow-up to `done/dcb-statechange-slice-per-command-mutations.md`
(shipped `reventless-core@3.0.0-alpha.148`, commit `136fe93c5`). That fix made DCB
StateChangeSlices emit one mutation per command constructor (good), but chose the
**aggregate** naming convention `${plugin}_${slice}_${command}`
(`Api_Naming.sliceMutationFields` → `aggregateMutationField`). For a multi-command slice
this is wrong on two counts, and it is **deploy-blocking** for any platform with a
long-named multi-command DCB slice.

**Discovered by:** a downstream platform-inspector plugin bumping to the 148 train to pick
up this very fix. Its `pulumi preview` now fails at AppSync schema creation. Framework-neutral:
any multi-command DCB slice whose `plugin`+`slice`+`command` names are long enough, or whose
caller expects `${plugin}_${command}`, hits this.

## Two defects

### D1 — Subscription field name exceeds AppSync's 50-char hard limit (deploy-blocking)

`Plugin_SubscriptionSchema.res` names each mutation-triggered subscription `on${fieldName}`
(`@aws_subscribe`). With the new multi-command mutation field
`${plugin}_${slice}_${command}`, the subscription becomes
`on${plugin}_${slice}_${command}`.

Live failure (inspector, plugin=`Platform`, slice=`SyncExtensionWiring`, command
=`RemoveExtensionWiring`):

```
Schema creation failed for API …: Schema has the following errors:
 - The subscription field name is too long. Max characters allowed: 50
```

- mutation field `Platform_SyncExtensionWiring_RemoveExtensionWiring` = **50** chars (at the
  cap for a field, but…)
- subscription field `onPlatform_SyncExtensionWiring_RemoveExtensionWiring` = **52** chars → over.

Even the *primary* one is at the edge: `onPlatform_SyncExtensionWiring_SyncExtensionWiring`
= 50 (passes by one). The `on` prefix + the redundant `slice_command` doubling is what
overflows.

### D2 — The primary command's mutation is renamed, breaking existing callers

The old rule named a slice's mutation `${plugin}_${slice}` (e.g. `Platform_SyncComponent`).
Under the new multi-command rule the SAME field becomes `${plugin}_${slice}_${command}` =
`Platform_SyncComponent_SyncComponent` (redundant doubling), and the added command becomes
`Platform_SyncComponent_RemoveComponent`.

But every existing caller — and the original per-command plan's own acceptance — expects
`${plugin}_${command}`:
- the inspector's sync path sends `Platform_SyncPlatform`, `Platform_SyncPlugin`,
  `Platform_SyncComponent`, `Platform_SyncResource`, `Platform_SyncExtensionWiring`.
- the inspector's reconcile-remove path sends `Platform_RemoveComponent`, `Platform_RemoveResource`,
  `Platform_RemovePlugin`.
- the per-command plan's handoff said the reconcile caller would "start removing dropped
  components/resources" once `Platform_Remove*` **(i.e. `${plugin}_${command}`)** appeared —
  not `Platform_Sync*_Remove*`.

So even with D1 fixed, the whole sync + reconcile path would call fields that don't exist.

## Root cause

`Dcb_Builder` was changed to derive fields from
`Api_Naming.sliceMutationFields(~plugin, ~slice, ~commandSchema)`, whose multi-command branch
reuses `aggregateMutationField(~plugin, ~aggregate=slice, ~command=ctor)` =
`${plugin}_${aggregate}_${command}`. That convention makes sense for **aggregates** (multiple
aggregates coexist under a plugin, so the aggregate name namespaces the command). DCB slices
don't need it: the command constructor already names the operation, and callers/plans treat
the mutation as `${plugin}_${command}`.

## Proposed fix

Name DCB StateChangeSlice command mutations **`${plugin}_${command}`** (one per API-exposed
constructor), not `${plugin}_${slice}_${command}`:
- primary stays byte-identical to today's single-command output only when command==slice by
  coincidence; in general it becomes `${plugin}_${command}` (e.g. `Platform_SyncComponent`,
  `Platform_RemoveComponent`) — which is exactly what callers already use.
- subscription `on${plugin}_${command}` = `onPlatform_RemoveExtensionWiring` = 32 chars,
  comfortably under 50.

Add a dedicated `Api_Naming` helper for the DCB case (don't overload `aggregateMutationField`),
e.g. `dcbCommandMutationField(~plugin, ~command)` → `${plugin}_${command}`, and have
`sliceMutationFields` map API-exposed constructors through it. Keep the single-command
byte-identical guarantee where command list length ≤ 1.

**Collision note:** `${plugin}_${command}` assumes command-constructor names are unique across
a plugin's DCB slices (they are in the inspector). If core must defend against cross-slice
command-name collisions in general, prefer disambiguating only on collision (fall back to
`${plugin}_${slice}_${command}` for the colliding pair) rather than always doubling — and even
then, guard the resulting `on…` length against the 50-char AppSync cap with a clear build-time
error (not a deploy-time AppSync 500).

## Tests

- Schema-diff/unit: a 2-command DCB slice emits `${plugin}_${cmdA}` and `${plugin}_${cmdB}`
  mutations + `on…` subscriptions, and asserts each `on…` subscription name ≤ 50 chars.
- Regression: a slice whose `plugin`+`command` would exceed 50 fails at **build** with an
  actionable error, not at AppSync schema push.
- Byte-identical guard for single-API-command slices retained.

## Downstream impact / unblock

A downstream inspector platform bumped to the 148 train (build + tests green) **cannot
redeploy** until this lands — the schema push fails (D1) and the mutation names wouldn't
match the caller (D2). Such a platform either holds on 148 or temporarily reverts to the
prior train until the corrected naming ships, then re-bumps and redeploys. No downstream
code change is expected once the naming is `${plugin}_${command}`.
