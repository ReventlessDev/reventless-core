# Plan: Derive the platform's own component metadata from its specs

**Status:** Ready to start (not started)
**Date:** 2026-08-18

**Analysis:** [plugin-aggregate-readmodel-vs-normal-harmonization.md](../analysis/plugin-aggregate-readmodel-vs-normal-harmonization.md)
**Supersedes:** item 3.3 of [admin-readmodel-full-harmonization.md](Backlog/admin-readmodel-full-harmonization.md)
(that item was written against a four-read-model admin that no longer exists, and
against a dependency that was rejected — see its own re-scope warning)

---

## Goal

`Platform_Admin_Structure.res` hand-writes the `pluginStructure` that
`Plugin_Structure.make` derives for every ordinary plugin. Delete the hand-written
data and derive it from `PluginSpec` / `PluginsReadModelSpec`, so the platform's own
components are described by the same mechanism that describes everyone else's.

This is not tidying. The hand-written copy has to track `PluginBehavior.decide` and
the generated SDL by hand, and it has drifted from both.

---

## Why — four drifts found in one file

Three were fixed by declaring `@transition` on `PluginSpec.command` and reading it
back (`fix(core): give the Plugin lifecycle its transitions back`):

| Drift | Symptom |
|---|---|
| `Activate` declared `["Inactive"]` | `decide` also accepts `Retired` — the archive looked one-way |
| every `targetState` was `None` | AutoUI reads that as "this command does not move the row"; the Plugins lifecycle board drew four states and **no edges** |
| `Retire` had no `commandDef` | a live mutation with no metadata; its column read "No commands available" |

The fourth is still open and is the reason this plan exists:

**The command argument schema is missing a required argument.** The SDL declares

```graphql
Platform_Plugin_Activate(_0: String!, id: ID!): CommandResult!
```

but `Platform_Admin_Structure` describes the arguments with a local
`idArgs = {id}` — no `_0`, the target version. AutoUI builds its command form from
that schema.

**Open question, and step 0 of this plan:** does that make the Deactivate / Retire
row actions fail at call time with "argument `_0` required"? Verify on an isolated
memory-backend platform (never against a live `.reventless/local.db`). If they fail,
this is a live bug and the plan's priority changes accordingly.

A derived schema cannot have this class of fault: it is produced from the same
`commandSchema` the SDL is generated from.

---

## What was checked, and what it changed

The analysis lists three "incidental" forces keeping the admin off the generic path.
Two of them turned out not to exist:

**Naming is not bespoke.** `Api_Naming.adminField(~name=X)` is literally
`` `Platform_${X}` ``, and the generic
`queryFieldNamesForReadModel(~plugin="Platform", ~name="Plugins")` returns

```
singleFieldName: Platform_Plugin     listFieldName: Platform_Plugins
returnTypeName:  Platform_Plugin     pluralTypeName: Platform_Plugins
```

— byte-identical to the hand-written names. `singularize` already handles the
plural-spec-name/singular-type "mismatch" the analysis flagged. Nothing to build.

**`@hidden` in the query selection is a bug, not a missing annotation.**
`AutoUI.buildFieldSelection` selects `properties->Dict.keysToArray` — every property,
with no `x-reventless-hidden` check. `@hidden` hides columns (`AutoColumns.res`) but
the field is still fetched. That is why `apiSchemaFragment` / `structure` need
`encodeSchemaExcluding` today.

**Force 1 (bootstrapping) is real and does not go away.** The platform cannot hand
itself `module(Aggregate.T)` at structure-assembly time, so `Plugin_Structure.make`
stays unusable here. But `make` is not what is needed — its *extractors* are, and
they take schemas.

---

## Steps

Each is shippable on its own, in this order.

### Step 0 — Establish whether the missing `_0` is a live bug

Isolated memory-backend platform on alt ports; drive the Deactivate row action; record
whether the mutation is rejected. Report the finding before writing code.

### Step 1 — Derive the command defs

- Lift `extractCommandDefs` from a local binding inside `Plugin_Structure.make`
  ([Plugin_Structure.res:857](../../reventless/core/src/plugin/component/Plugin_Structure.res#L857))
  to module level. Mechanical; no behaviour change.
- Call it once with `PluginSpec.commandSchema`, the already-exported
  `PluginSpec.commandAuthorization`, and a `mutationFieldFor` composed the way
  `PluginBaseFragment` composes the field it generates.
- Delete `idArgs`, `lifecycleCommand`, and the three hand-written records.

Yields all eight variants, including the `@noApi` protocol ones with
`apiExposed: false` — which is what puts `Connect` / `Disconnect` / `Heartbeat` on
the event graph. Fixes the `_0` gap by construction.

**Verify:** emitted defs unchanged for the three exposed commands except the
argument schema, which gains `_0`; `pnpm run check:graphql` unchanged; the Plugins
lifecycle board still draws its seven edges.

### Step 2 — Honour `@hidden` in the AutoUI query selection

**Cross-repo (`reventless-ui`).** Skip `x-reventless-hidden` properties in
`buildFieldSelection`. General benefit: today every hidden field is fetched over the
wire on every list query.

Once this lands, `apiSchemaFragment` / `structure` need only `@hidden` on the spec,
and `pluginUIOnlyExcludeFields` goes away.

### Step 3 — `@internal`: a field that is not on the GraphQL surface

The one genuinely new primitive. A field that exists in the record and in storage but
is not exposed:

```rescript
@schema
type state = {
  name: Reventless.Plugin.name,
  status: status,
  @internal eventCollector: string,
  @internal extensionPointNames: array<string>,
  @internal extensionNames: array<string>,
}
```

Named for the existing component-level `@@reventless.visibility(Internal)` — same
word, one level down. Emits `x-reventless-internal: true`; codegen drops the field
from the generated SDL type and from `queryableDef.schema`. Projection and storage
are untouched.

**Compile-time rules:** rejected together with `@id` / `@index` / `@indexSubId` /
`@owner` / `@retired` (each keys a door that would then name a field the SDL does not
have) and with `@summary`.

**Not a security boundary** — same caveat as `visibility(Internal)`. It shapes the
generated surface; `@owner` / `@retired` remain the enforcement markers.

**First task of this step is a survey, not code:** enumerate every codegen path the
marker must reach — SDL generation, `queryableDef.schema`, the AppSync and local
resolvers, the JSON-schema walkers, MCP tool generation — and confirm each has a
single place to honour it. If it does not, that is the finding, and the step is
re-scoped before anything is written.

**Why it is worth a primitive rather than a special case:** a read model's
`@schema type state` is today simultaneously the storage shape and the API shape,
with no way to separate them. `Plugins` hits this hardest, but denormalised
projection keys, sync cursors/watermarks, fields already served by a dedicated
resolver, and migration scaffolding all hit it. The workaround — splitting the record
into a storage type and a view type — duplicates the schema and reintroduces exactly
the drift this plan exists to remove.

### Step 3a — Declare the internal commands' lifecycle edges

Independent of steps 3–5; do it any time after step 1.

The non-exposed commands move rows too, and nothing says so:

```rescript
| @noApi @transition(([Plugins.Connected]) => Plugins.Disconnected) Disconnect(version)
| @noApi @transition(=> Plugins.Connected) Connect(pluginDefinition)
```

(the creating form's syntax needs checking — `Connect` has no from-state, and
`@transition` may not accept a target-only edge today. If it does not, that is a PPX
change and belongs to this step.)

With step 1 emitting their `commandDef`s, the platform then publishes the complete
lifecycle graph — including the only edge into `Disconnected`, which
`checkLifecycleTopology` currently reports as unreachable.

**This does not by itself put them on the lifecycle diagram.**
`ComponentDefinitionsDecoder` drops `apiExposed: false` at the pipeline boundary, so
they reach the event graph and stop there. Drawing them is a `reventless-ui` change,
planned on that side; the two halves are independent and this one is useful alone —
it makes the published graph complete and lets the topology check pass honestly.

**The property the UI side must keep:** these commands have no mutation field
(`mutationField: ""`) and must stay uncallable — `Connect` carries a whole plugin
definition. Publishing metadata about an edge is not publishing a way to invoke it.

### Step 4 — Declare the read model's authorization on the spec

`PluginBaseFragment.adminAuth = {tableName: "Plugin", group: "Admin"}` is
hand-written. The spec carries only `authorization = AllowAuthenticated`, which is a
different type (query permission, not the AppSync group gate). Per-`@index`
`group`/`authTable` exists; a record-level equivalent does not.

Make it declarable on the spec, then read it rather than restate it.

### Step 5 — Derive the `queryableDef`

With 2–4 in place, the remaining fields (`queryField`, `singleQueryField`,
`labelField`, `searchableFields`, `idField`, `schema`) come from the generic helpers.
`lifecycleField` already does.

Needs a structure-assembly entry point that takes **specs** rather than functor
modules — the Force 1 accommodation. That entry point is the deliverable, not a
workaround.

---

## Out of scope

- **`Platform_UIFragments`** — item 3.1 of the harmonization plan. Different
  component, blocked on a coordinated host-shell change (flat `[X!]!` → `Connection`).
  It does not block the `Plugins` half.
- **`Plugin_Structure.make` itself** — Force 1 is real; this plan routes around it via
  the extractors rather than pretending it away.
- **Drawing the internal commands' edges on the lifecycle diagram.** Steps 1 and 3a
  publish them; rendering them is a `reventless-ui` change, planned on that side.

---

## Risks

- **Step 3 is the only one that adds surface area.** If the survey finds the marker
  has to be honoured in many places, prefer re-scoping to `Plugins` only over
  threading a half-supported annotation through the codegen.
- **Step 2 is cross-repo** and changes what every AutoUI list query selects. Low risk
  (it removes fields the UI was already hiding) but it is a wire change; verify a
  hidden field is still reachable through a drill/detail path that asks for it.
- **Step 1 changes the published command-argument schema**, which is what AutoUI
  builds forms from. That is the point — but it means the row actions must be
  re-driven in a browser, not just unit-tested.

---

## Verification

Each step: full build zero warnings, `pnpm test` green, `pnpm run check:graphql`
unchanged (or goldens refreshed in the same commit if the SDL genuinely moves), and
the Plugins lifecycle board plus the row action menu driven in the host shell.
