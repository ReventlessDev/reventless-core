# The platform shows up as a `Platform` row in the admin Plugins list

**Status:** **A1 core surface implemented** 2026-07-08 (analysis 2026-07-08; mechanism
corrected + Option-B precondition verified; A1 implemented — build clean, tests green).
Remaining: the admin-console panel split (UI repo) and the inspector-side reconcile
filter (both downstream, now unblocked by the exposed `kind`).
**Area:** plugin-lifecycle read model / plugin deploy handshake / admin Plugins view
**Related:** [done/platform-plugins-admin-connection-null-rows.md](done/platform-plugins-admin-connection-null-rows.md)
(same admin `Platform_Plugins` surface — that one fixed internal *rows* leaking; this
one is about a real entity of the wrong *kind* leaking into the same list)

## Symptom

On a platform that deploys a **platform-inspector** infrastructure plugin, the admin
Plugins page lists a `Platform` row alongside the domain plugins (e.g. `Ordering`,
`Catalog`). It:

- shows status `Disconnected` — which is meaningless for infrastructure (it has no
  extension points to wire, so it can never become `Connected`), yet reads like a fault;
- carries a framework-scheme version (`3.0.0-alpha.NN`) unlike the domain plugins'
  `1.0.0-alpha.NN`;
- is conceptually the *host*, not a peer of the domain plugins.

A platform **without** an inspector shows no such row — the admin console and schema
stitching work fine without it — so this is inspector-introduced, not load-bearing.

## Correction — the original "Where it comes from" was wrong

The first draft of this plan asserted that the inspector registers `kind:
PlatformInfrastructure` via `Plugin_BuiltHook.registerPluginMetadata`, and that this
"lands a `PlatformInfrastructure`-kind entity in the plugin-lifecycle read model
(`PluginsProjection`)" which the `Platform_Plugins` connection then returns. **A code
trace shows that causal chain does not exist.** The correction below replaces it, and
the options/recommendation are re-derived from the real mechanism.

## Where the `Platform` row actually comes from (verified)

The inspector is a normal plugin **named `"Platform"`**, deployed like any other via
`Platform.deployPlugin(~plugin=…, ~apiTarget=Platform)`.

`deployPlugin` wires the **runtime plugin-lifecycle handshake** for every plugin it
deploys. It fires a synthetic `Heartbeat(timeout)` command onto the
plugin-extension-point FIFO command topic
([reventless-aws/src/Platform.res:2123](../../reventless/reventless-aws/src/Platform.res#L2123)),
and a recurring heartbeat rule keeps re-firing it. That `Heartbeat` drives the built-in
Plugin aggregate ([PluginBehavior](../../reventless/reventless-core/src/plugin/lifecycle/PluginBehavior.res) /
[PluginExtensionPoint_Plugin](../../reventless/reventless-core/src/plugin/connect/PluginExtensionPoint_Plugin.res))
→ `VersionDetected` → `VersionConnected`/`VersionDisconnected` →
the [`PluginsProjection`](../../reventless/reventless-core/src/plugin/lifecycle/PluginsProjection.res)
row. That projected row — keyed by plugin **name** — is exactly what `Platform_Plugins`
lists. It is named `Platform` because the inspector plugin's name is `Platform`.

`kind` plays **no part** in this. Concretely:

- `pluginMetadataRegistry` (where `registerPluginMetadata` stores `kind`) is read in
  only two places — [Plugin_Builder.res:483](../../reventless/reventless-core/src/plugin/component/Plugin_Builder.res#L483)
  and [Plugin_Helpers.res:1706](../../reventless/reventless-core/src/plugin/component/Plugin_Helpers.res#L1706) —
  both feeding the **deploy-time** `pluginBuiltInfo` / `pluginDeployedInfo` used by the
  SDK metadata hooks (the `plugin-info:*` rows). Those internal rows carry no `name` and
  are **already excluded** from `Platform_Plugins` by the fix in
  [done/platform-plugins-admin-connection-null-rows.md](done/platform-plugins-admin-connection-null-rows.md)
  (`df14af2cb`, `attribute_exists(#name)`).
- [`PluginsReadModelSpec.state`](../../reventless/reventless-core/src/plugin/lifecycle/PluginsReadModelSpec.res#L17)
  has **no `kind` field**, and `ReventlessSpec.Plugin.pluginDefinition`
  ([Plugin.res:347](../../reventless/reventless-spec/src/components/Plugin.res#L347)) —
  the payload carried through the handshake — has **no `kind` field** either. `kind`
  therefore never reaches the lifecycle model.

**Implication:** Option B *as originally written* ("don't write a
`PlatformInfrastructure` entity into the plugin-lifecycle read model") targets a write
that does not exist / is already filtered. Not calling `registerPluginMetadata` is a
**no-op for this symptom** — the `Platform` row is produced by the deploy handshake, not
by the kind metadata. Any real fix must act on the handshake/lifecycle path or on the
connection view, not on `registerPluginMetadata`.

## What actually consumes the `Platform` lifecycle row (verified)

- **Nothing but the list view.** No console/UI code reads the inspector's
  `Platform_Plugin(s)` lifecycle row beyond the kit's Plugins overview.
- **Not schema stitching.** Platform-target plugins persist their schema fragment under
  the `deploy-schema-platform:` namespace at deploy time, and the platform stitches from
  there ([Platform.res:744-816](../../reventless/reventless-aws/src/Platform.res#L744)) —
  independent of whether the plugin appears in the lifecycle projection.
- **Not the platform reconcile.** The reconcile that emits `Platform_RemovePlugin` reads
  the platform **health summary** view (the correct home for platform observability),
  **not** the core plugin lifecycle registry.

So the inspector's plugin-lifecycle row has **no consumer that needs it**; platform
observability lives (correctly) in the platform-overview / health-summary views.

## Option-B precondition — VERIFIED (holds)

**Question:** if the inspector plugin skips the lifecycle handshake (so no
`PluginsProjection` row), does its own GraphQL API still stitch correctly?

**Answer: yes.** Two independent facts, both in core:

1. **The inspector's schema is a deploy-time push, not a handshake product.** Every
   plugin's fragment is written and cumulatively stitched during `deployPlugin` by
   `preResolversSchemaHook`; platform-target plugins use the `deploy-schema-platform:`
   namespace and the PlatformApi
   ([Platform.res:749-816](../../reventless/reventless-aws/src/Platform.res#L749)). This
   fires at deploy time regardless of the runtime `Heartbeat`.
2. **The only runtime re-stitch already excludes platform-target plugins.**
   `updateApiSchema` ([Platform.res:1634](../../reventless/reventless-aws/src/Platform.res#L1634))
   rebuilds only the **DomainApi** from `Connected` lifecycle rows and explicitly drops
   `apiTarget: Some("Platform")` fragments
   ([Platform.res:1647](../../reventless/reventless-aws/src/Platform.res#L1647)); the
   comment on [`PluginsReadModelSpec.state.apiTarget`](../../reventless/reventless-core/src/plugin/lifecycle/PluginsReadModelSpec.res#L28)
   documents this. There is **no** PlatformApi runtime re-stitch keyed off lifecycle
   rows.

So the lifecycle row contributes nothing to the inspector's API: the PlatformApi schema
comes entirely from the deploy-time namespace push, and the DomainApi re-stitch already
ignores platform-target plugins. Removing the row is schema-safe. (The inspector also
has no extension points/extensions, so the handshake's `DoConnectPlugin` cross-plugin
SNS wiring is already a no-op for it.)

## Interaction worth noting

The platform reconcile computes `toRemove = knownPlugins − registeredPlugins` and emits
`Platform_RemovePlugin` for the difference. `knownPlugins` comes from the health-summary
view (not the core lifecycle registry), so this interaction is orthogonal to the
`Platform` lifecycle row; it is only a concern if a future change routes infrastructure
through the same tracked set. Excluding infrastructure from any such diff remains
desirable.

## Options (re-derived from the real mechanism)

**(A) Connection view filter — but `kind` isn't in the model yet.** To exclude (or
segregate) infrastructure at the `Platform_Plugins` connection, the connection needs a
discriminator it does not currently have. Two sub-variants:

- **(A1) Plumb `kind` end-to-end:** add `kind` to `pluginDefinition` → carry it through
  the handshake events → add it to `PluginsReadModelSpec.state` → filter/segregate
  `PlatformInfrastructure` in the `Platform_Plugins` resolver (or the kit overview).
  Larger, but keeps the registry complete and enables a proper "System / Infrastructure"
  panel. This is the honest form of the original "cheap view filter" idea.
- **(A2) Name-based exclusion:** filter the well-known `Platform` name out of the
  connection. Cheap but brittle (couples the core connection to a specific plugin name);
  not recommended except as a stopgap.

**(B) Keep the platform out of the lifecycle registry at the source — verified viable.**
Give `deployPlugin` a way to deploy an infrastructure plugin **without** the runtime
lifecycle handshake — an `~infrastructure`/`~kind` flag that suppresses both heartbeat
sources: the synthetic deploy-time `Heartbeat`
([Platform.res:2123](../../reventless/reventless-aws/src/Platform.res#L2123)) and the
recurring heartbeat rule (via the heartbeat-config registration). With no `Heartbeat`
there is no `VersionDetected`, so no `PluginsProjection` row is ever created. Entirely
within core (`reventless-aws/src/Platform.res` + the heartbeat-config path); the
schema-stitching precondition above is **verified to hold**, and the inspector has no
extension wiring that depends on the handshake. Truest to "the platform is not a plugin."

## Decision — pursue (A1)

Between the two viable end states, we are pursuing **(A1): plumb `kind` end-to-end and
segregate infrastructure into a visible "System / Infrastructure" panel** rather than
**(B): hide it at the source**. Both fix the mislabel; the reason to prefer A1 is that
**B *discards* a discriminator while A1 *invests* in one**. B suppresses the infra
plugin so nothing downstream ever needs to tell kinds apart; A1 makes `kind` truth in the
data, after which "show a panel" vs. "hide" is a cheap view decision on top. The
opportunities below are really the opportunities of *having `kind` in the lifecycle model
at all*.

(Avoid the original framing — acting on `registerPluginMetadata` — which does not affect
this row. **(A2)** remains only an emergency stopgap. **(B)** stays documented above as
the smaller alternative if the roadmap never grows a second non-`Domain` kind.)

## Opportunities of A1 (a visible System/Infrastructure panel)

1. **Correct semantics instead of a mislabel.** Infrastructure carries
   infrastructure-appropriate status (deployed / version / healthy) rather than the
   domain lifecycle `Connected`/`Disconnected` — killing the "reads like a fault" problem
   **without** pretending the component doesn't exist.
2. **Self-observability of the observer.** The inspector powers the whole console
   (PlatformOverview, ResourceInventory, EventFlow, CommandRoutes, SchemaCatalogue,
   health, environment comparison). A System panel is a self-diagnostic — "is the
   observer deployed, what version, is it healthy?" Fully hiding it (B) removes that
   in-console signal when the console goes blank.
3. **A front door for data already collected.** Those infra read models exist but are
   orphaned; the (currently mislabeled) `Platform` entry becomes the navigable index into
   platform version, deployment history/timeline, schema history, breaking-change index,
   and environment drift.
4. **The `kind` enum already anticipates more than infrastructure.** It is
   `Domain | PlatformInfrastructure | Commercial | Marketplace`
   ([Plugin_BuiltHook.res:16](../../reventless/reventless-core/src/plugin/component/Plugin_BuiltHook.res#L16)).
   Plumbing `kind` once yields segregation for *all four* — future Commercial/Marketplace
   surfaces come for free instead of re-litigating this.
5. **No silent-leak regressions.** With `kind` in the model, every new infra plugin
   classifies correctly by construction. B's opt-out flag must be *remembered* per
   plugin; forget it and infrastructure silently rejoins the domain list.
6. **Audience/role separation.** Domain plugins are for app developers; infrastructure is
   for platform admins (the audience already gated on `PlatformAdmin`). A segregated panel
   maps cleanly to that split.
7. **Cleaner fix for the reconcile edge case.** The `Platform_RemovePlugin` diff needs
   kind-awareness to avoid flagging infrastructure for removal. A1 puts `kind` exactly
   where that logic can read it, rather than avoiding the problem by removing the row.

**Costs acknowledged:** larger surface (new field threaded spec → handshake → projection
→ SDL/resolver + a UI panel); a default for kind-less persisted rows; and A1 *re-labels*
rather than *removes* — the infra plugin still heartbeats and still holds a lifecycle row.

## A1 implementation plan

All steps are core-repo unless noted. `kind` rides the handshake for free once it is on
`pluginDefinition` (the lifecycle events `VersionConnected(def)` etc. already carry the
whole definition), so the spine of the work is: **source the kind → put it on the
definition → project it → expose + segregate it**.

1. **Model — add `kind` to the definition (spec). ✅ done.**
   - Added `@schema type pluginKind = Domain | PlatformInfrastructure | Commercial |
     Marketplace` as the canonical enum in `reventless-spec`
     ([Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res)) — it must
     live here because `pluginDefinition` (a `@schema` type in the lifecycle Message
     union) needs the sury schema, and spec is the lowest package.
     [Plugin_BuiltHook.res](../../reventless/reventless-core/src/plugin/component/Plugin_BuiltHook.res)
     now **re-exports** it (`type pluginKind = Reventless.Plugin.pluginKind = | Domain |
     …`) so the deploy-metadata registry and the serialized definition share **one** type
     — no second enum, no mapping.
   - **`kind` is mandatory, not optional.** The first draft proposed an optional field
     "so kind-less events decode as `Domain`", but the JSON-safe `js_nullable` encoding
     (the only form that passes sury's `jsonableValidation` inside the Message union) is
     **present-required on decode either way** — `option` buys no migration tolerance, only
     an unwanted `None`-vs-`Domain` split. So `kind: pluginKind` is mandatory (payload-less
     variant → bare JSON string → JSON-safe with no `js_nullable`). `Domain` is the default
     value, resolved **once** at the deploy-metadata → definition boundary (Plugin_Builder,
     `->Option.getOr(Domain)`) and hard-set `Domain` at the other construction sites. This
     gives a non-null `kind: PluginKind!` GraphQL field. Consequence: a definition
     persisted before `kind` existed does not decode — it re-emits on the next deploy
     handshake (or is wiped, per alpha practice); there is no migration *code*, but it is
     re-emit-on-deploy, not a decoder default.

2. **Source — populate `kind` where the definition is built. ✅ done.**
   - `makePluginDefinition` / `Plugin.make` set `kind` from the deploy-time
     `pluginMetadataRegistry` — the value is already in hand at
     [Plugin_Builder.res:483](../../reventless/reventless-core/src/plugin/component/Plugin_Builder.res#L483)
     (and [Plugin_Helpers.res:1706](../../reventless/reventless-core/src/plugin/component/Plugin_Helpers.res#L1706)),
     currently only forwarded to `pluginDeployedInfo`. Thread the same
     `meta.kind` onto the definition. Default `Domain` when absent.
   - The admin `fakePluginDefinition`
     ([Platform_Admin.res:70](../../reventless/reventless-core/src/admin/Platform_Admin.res#L70))
     gets `kind: Domain` (or a dedicated `Admin`/infra classification — decide in review).

3. **Project — carry `kind` into the read model. ✅ done.**
   - Add `kind` to [`PluginsReadModelSpec.state`](../../reventless/reventless-core/src/plugin/lifecycle/PluginsReadModelSpec.res#L17)
     (and the `queryResult` type alongside it).
   - Set it in `displayState`
     ([PluginsProjection.res:41](../../reventless/reventless-core/src/plugin/lifecycle/PluginsProjection.res#L41))
     from `def.kind` — every `VersionConnected/Promoted/Disconnected/...` arm already flows
     through `displayState`, so this is one assignment.

4. **Expose — surface `kind` on the GraphQL Plugin type. ✅ done (auto-derived).**
   - Add a `PluginKind` SDL enum and a `kind: PluginKind!` field, following the existing
     `PluginStatus` enum precedent in
     [AdminApi.res:53](../../reventless/reventless-core/src/admin/AdminApi.res#L53) and the
     `PluginBaseFragment.queryEntries` that back `Platform_Plugins`.

5. **Segregate — filter/partition at the connection. ✅ done (option (a): `@scan` → `kindEq`).**
   - The `Platform_Plugins` connection resolver already learned an attribute filter in
     `df14af2cb`
     ([QueryDbResolvers_AppSync.res](../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)).
     Two shippable shapes: (a) expose `kind` and let the caller filter (thinnest core
     change; the panel split lives in the view), or (b) add a first-class
     kind-scoped/segregated connection. Precedent that reading a state field at the
     resolver/stitch layer is fine:
     [Platform.res:1647](../../reventless/reventless-aws/src/Platform.res#L1647) already
     branches on `state.apiTarget`. Prefer (a) unless the view needs server-side paging
     per kind.

6. **Reconcile — make the removal diff kind-aware. ⛔ downstream (not in this repo).** The
   `Platform_RemovePlugin` reconcile lives in the inspector, not `reventless-core`; now
   unblocked because `kind` is queryable. Ensure the platform reconcile that
   emits `Platform_RemovePlugin` excludes `PlatformInfrastructure` (now readable from the
   row/definition), closing the latent mismatch noted above.

7. **View — the System/Infrastructure panel. ⛔ downstream (UI repo).** With `kind` exposed,
   the admin console groups `PlatformInfrastructure` (and later Commercial/Marketplace)
   into a separate panel with infra-appropriate status. **Out of scope for this core plan;
   tracked as a UI-repo follow-up** — core’s deliverable is the exposed `kind` + connection
   segregation.

8. **Tests. ✅ done** (kind-less→`Domain` is now a build-time default, not a decode case —
   see step 1). Extend `PluginsProjection_GWT` for `kind` projection (incl. the kind-less →
   `Domain` default on replay); add a `QueryDbResolvers_AppSync` case for the
   kind filter/segregation (sibling to the `df14af2cb` regression test); a decode test
   asserting an old kind-less event yields `Domain`.

**Suggested sequencing:** 1→2→3 land together (model + source + projection, behind an
exposed-but-unused field), then 4→5 (SDL + connection), then 6, then the UI panel. Each
prior step is independently valid and warning-clean.

## Open questions

- **Admin/internal classification:** should the built-in `Admin` `fakePluginDefinition`
  be `Domain`, or gain its own infra-style classification? (Affects whether Admin also
  moves to the System panel.)
- **Default locus (RESOLVED):** `kind` is mandatory; the `Domain` default is resolved at
  **build time** (Plugin_Builder `->Option.getOr(Domain)` + hard-set `Domain` at the other
  construction sites), not in a decoder. The earlier "decoder default" idea was moot — the
  JSON-safe encoding is present-required on decode regardless — so kind-less persisted
  events re-emit on the next deploy (or are wiped) rather than decoding to a default.
- **In-memory limitation (note):** the `reventless-local` handshake hard-sets `kind:
  Domain` (it builds defs for all plugins from a shared path and the metadata registry is
  a single global ref, so it can't per-plugin-source `kind` safely). The AWS path is
  per-stack/process, so its registry read is correctly isolated. In-memory inspector
  segregation is therefore not wired — acceptable, since the target is the AWS console.
- Does any commercial read model / Event Graph / extension-wiring path key off `kind` in
  a way that a new required-with-default field would disturb? (None found; the only
  consumer of the lifecycle row today is the Plugins overview.)

## Acceptance

- `Platform_Plugins` exposes `kind`; the admin console shows domain/commercial plugins in
  the main list and `PlatformInfrastructure` in a separate System / Infrastructure panel
  with infra-appropriate status (no misleading `Connected/Disconnected` chip).
- A plugin deployed with no kind metadata classifies as `Domain` (build-time default). No
  migration *code* is written; a definition persisted before `kind` existed re-emits on
  the next deploy handshake (or is wiped, per alpha practice) rather than decoding via a
  default — a consequence of the mandatory-`kind` decision (see implementation step 1).
- Platform observability remains available via the platform-overview / health views.
- The reconcile never emits `Platform_RemovePlugin` for a `PlatformInfrastructure`
  entity.
- Zero new compiler warnings.
