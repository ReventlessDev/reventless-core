# Plan: Derive the platform's own component metadata from its specs

**Status:** Steps 0, 1 and 3a landed. Steps 2 (other repo), 3, 4, 5 open.
**Date:** 2026-08-18
**Analysis it produced:** [plugin-command-union-decode-failure.md](../analysis/plugin-command-union-decode-failure.md)
— found while verifying step 0, unrelated to this plan, and the reason
"drive it in a running shell" cannot currently be a verification for anything here.

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

**Answered — it is a live bug.** Driven against an isolated memory-backend platform
on alt ports. The document AutoUI builds from the published schema:

```
mutation Platform_Plugin_Deactivate($id: ID!) { Platform_Plugin_Deactivate(id: $id) { … } }
→ Field "Platform_Plugin_Deactivate" argument "_0" of type "String!" is required,
  but it was not provided.   (GRAPHQL_VALIDATION_FAILED)
```

The same mutation with `_0` supplied is accepted. So all three admin row actions —
Activate, Deactivate, Retire — were rejected before reaching the aggregate, and this
plan's step 1 is a fix rather than cleanup.

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

### Step 0 — Establish whether the missing `_0` is a live bug — **DONE**

Answered above: yes. See "Why — four drifts found in one file".

### Step 1 — Derive the command defs — **DONE**

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

**Verified.** All eight variants emitted; the three exposed ones keep their
`Platform_Plugin_*` field names and gain `_0`; the five `@noApi` ones carry
`apiExposed: false` and the empty `mutationField` sentinel. `aggregateIdField` is now
`None` rather than `Some("id")` — which is what every ordinary aggregate command
publishes, and what makes the consumer inject `id: ID!` alongside `_0`. The SDL is
untouched (it is generated from `PluginBaseFragment`), and `check:graphql`'s document
half is unchanged.

The lifecycle board could not be driven — see the decode-failure analysis; there are
no plugin rows on any local platform. Verified against what
`Platform_ComponentDefinitions` publishes instead.

### Step 2 — Honour `@hidden` in the AutoUI query selection — **DONE (other repo)**

**Cross-repo (`reventless-ui`).** Skip `x-reventless-hidden` properties in
`buildFieldSelection`. General benefit: today every hidden field is fetched over the
wire on every list query.

Once this lands, `apiSchemaFragment` / `structure` need only `@hidden` on the spec,
and `pluginUIOnlyExcludeFields` goes away.

**The consuming half is not done and is deliberately not part of step 2.** Putting
`@hidden` on those two spec fields and dropping them from
`pluginUIOnlyExcludeFields` is a change *here*, and it is only safe once every shell
reading this platform skips hidden fields in its selection — i.e. after the consuming
repo publishes and the pin moves. It belongs with step 5, which is the next thing to
touch that file anyway. `pluginExcludeFields` (the three storage-only fields) stays
regardless until step 3: those are absent from the SDL, not merely unwanted, and
`@hidden` does not remove a field from the surface.

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

**First task of this step is a survey, not code** — **DONE, and the answer is
favourable.** Every path has a single place to honour the marker, and one path turns
out to need nothing at all:

| Path | Where it is honoured | Notes |
|---|---|---|
| SDL generation | `GraphQL_FragmentGenerator.deriveObjectTypeWithNested(~excludeFields)` | one call site (line ~712), already parameterised — the marker feeds the list `PluginBaseFragment` hand-writes today |
| `queryableDef.schema` | `SuryToJsonSchema.deriveObjectSchema` | `Plugin_Structure` derives it at two sites, but both go through this one walker |
| JSON-schema walkers | `SuryToJsonSchema.deriveObjectSchema` | 73 references, one definition — the same single point as the row above |
| AppSync + local resolvers | **nothing** | neither projects by field name; they hand back whole rows and GraphQL's type system is the gate |
| MCP tool generation | `MCP_SchemaGenerator` | derives *command* variant schemas, and `@internal` is a read-model state marker — unaffected unless MCP grows query tools over state |

The resolver row is the one worth stating plainly, because it was the plan's main
worry. Verified rather than reasoned: an already-excluded field on the live platform
is rejected at **validation**, not filtered at serialisation —

```
{ Platform_Plugins { edges { node { name eventCollector } } } }
→ Cannot query field "eventCollector" on type "Platform_Plugin".
```

So excluding a field from the generated SDL type is the whole gate for the read
surface, and `@internal` needs no resolver change on either adapter.

**The one thing to confirm before writing code:** that dropping internal properties
inside `deriveObjectSchema` cannot reach storage. It should not — that function
derives JSON Schema for publishing, while projection and storage use the sury schema
directly — but it is the assumption the whole shape rests on, and it is cheap to
check.

Re-scoping to `Plugins` only is therefore **not** indicated.

**Why it is worth a primitive rather than a special case:** a read model's
`@schema type state` is today simultaneously the storage shape and the API shape,
with no way to separate them. `Plugins` hits this hardest, but denormalised
projection keys, sync cursors/watermarks, fields already served by a dedicated
resolver, and migration scaffolding all hit it. The workaround — splitting the record
into a storage type and a view type — duplicates the schema and reintroduces exactly
the drift this plan exists to remove.

### Step 3a — Declare the internal commands' lifecycle edges — **DONE**

Independent of steps 3–5; do it any time after step 1.

The non-exposed commands move rows too, and nothing says so:

```rescript
| @noApi @transition(() => Plugins.Connected) Connect(pluginDefinition)
| @noApi @transition(([Plugins.Connected]) => Plugins.Disconnected) Disconnect(version)
```

**The creating form did need a PPX change, and it landed with this step.** `()` is
the empty from-set: a command that brings the row into being has no state to run
from. It emits a `markTargetState` entry and **no** `markAllowedStates` one — an
entry with an empty array would publish `allowedStates: Some([])`, "legal in no
state", and every consumer that filters on it would hide the one command that creates
rows. `([]) => X` is refused with an error naming the `()` spelling, so there is one
way to write it.

`lifecycleTopologyFindings` was reading reachability off `(Some(froms), Some(to))`
pairs, which would have counted a creating edge as contributing nothing. It now reads
targets alone — the question it asks is only about arrival.

**Only these two are declared.** `Heartbeat` can also move a row (`Disconnected` →
`Connected` via `connectEvents`), but it is legal in every state and no-ops in most,
so an `allowedStates` naming the one state it moves from would be a false guard.
`Redetect` and `ReportIncompatibility` move nothing. An undeclared edge is not drawn,
which is the rule the guard-only work established and this keeps.

**Verified** on the live platform's published definitions:

```
Connect     exposed=False from=None          -> Connected
Disconnect  exposed=False from=['Connected'] -> Disconnected
```

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

**The last of those is currently unavailable**, and not for a reason this plan can
fix: no plugin connects on any local platform, so there are no rows to drive. See
[plugin-command-union-decode-failure.md](../analysis/plugin-command-union-decode-failure.md).
Steps 0, 1 and 3a were verified against what `Platform_ComponentDefinitions`
publishes — which is the thing they change — plus the full suite (346 suites, 3463
tests) and the PPX suite. Restore the shell check as soon as the decode bug is fixed;
step 1 in particular changes the schema AutoUI builds forms from, and a form is worth
seeing.
