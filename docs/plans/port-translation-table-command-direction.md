# Plan: the port's other half — the command direction's translation table

**Status.** Proposed 2026-08-27.

**Goal.** `extension-point-translation-table.md` (done) made the *event* flow across a port
visible: which internal event becomes which published event, and which published event becomes
which command. The *command* flow — an extension pushing a command back through the port into the
host's delegate — is still what that plan said the event flow was: a fact that exists only inside
a function body. Complete the pair.

**Relates to:**

- `done/extension-point-translation-table.md` — the first half. Everything below mirrors its
  vocabulary, its derivation and its escape hatch on purpose; read it first.
- `plugin-definition-schema-evolution-guards.md` — two more fields on a persisted def, so §6 is
  bound by it exactly as the first plan's §4.1 was.

---

## §1 — What is missing, precisely

A port has **four** mapping functions, two per side. Two are tabled:

| Side | Function | Direction | Table |
|---|---|---|---|
| ExtensionPoint | `mapOutgoingEvent` | Delegate event → EP event | `publishedEvents` |
| ExtensionPoint | `mapIncomingCommand` | EP command → Delegate command | **none** |
| Extension | `mapIncomingEvent` | EP event → Delegate / EP command | `handledEvents` |
| Extension | `mapOutgoingEvent` | Delegate event → EP command | **none** |

Both existing tables are keyed on the event flow. The command flow is undescribed on both sides,
and the omission is structural rather than incidental:

1. **The PPX has no arm for it.** `TranslationTable.target_of_action`
   ([TranslationTable.ml:72-85](../../packages/reventless-ppx/src/ppx/TranslationTable.ml#L72-L85))
   knows `PublishEvent`, `PublishAggregateCommand`, `PublishStateChangeSliceCommand` and
   `PublishExtensionPointCommand`. `ExtensionPointMapping.PublishCommand` — the only action
   `mapIncomingCommand` can return — falls to the catch-all and raises `Unfollowable`.
2. **Side detection doubles as function selection.**
   ([TranslationTable.ml:305-311](../../packages/reventless-ppx/src/ppx/TranslationTable.ml#L305-L311))
   reads which side a module is on off `mapIncomingEvent` vs `mapOutgoingEvent`, then derives the
   one table from that same binding. So an EP mapping's `mapIncomingCommand` is never reached, and
   an extension's `mapOutgoingEvent` is shadowed by the `mapIncomingEvent` branch that wins first.
   One module can only ever produce one table.
3. **The edge stops mid-air where it *is* recorded.** `handledEvents.toCommandTypes` does absorb
   `PublishExtensionPointCommand` arms, EP-qualified
   ([Plugin_Structure.res:1334-1348](../../reventless/core/src/plugin/component/Plugin_Structure.res#L1334-L1348)).
   `Plugin_Structure` can check that the name is a real EP command variant and nothing more —
   there is no table on the EP side saying what the port does with it. A consumer reading
   `handledEvents` sees a command leave and never sees it land.

**Why nobody noticed.** Every `mapIncomingCommand` in the three example shops is
`(_id, _command, _meta) => []`, and every example extension's `mapOutgoingEvent` is `None`. The
command half of the port is exercised only by the framework's own lifecycle port
([PluginExtensionPoint_Plugin.res:161-221](../../reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res#L161-L221),
[PluginExtensionPoint_UiFragment.res:28-47](../../reventless/core/src/plugin/connect/PluginExtensionPoint_UiFragment.res#L28-L47)),
which is exactly the code no example renders.

## §2 — Why this is worth doing on its own terms

The three consequences from the first plan's §2 apply unchanged to the direction it did not cover,
plus one that only exists once both halves are present:

- **Dead inbound protocol surface is undetectable.** The first plan's check found
  `PluginReconnected` — a published event no arm produces. The mirror defect is an EP `command`
  variant no `mapIncomingCommand` arm handles: an extension can send it, the port accepts the
  envelope, and nothing happens. That is worse than the event case, because the sender got no
  error and believes it commanded something.
- **`commandTypes` is a list with nothing joined to it.** `extensionPointDef.commandTypes` names
  the EP's inbound protocol and `extensionDef.commandTypes` names the same union from the
  subscriber's side. Neither says which delegate command an EP command becomes — the identical
  unjoinable-lists problem the first plan opened with, one field over.
- **The write path is the half that changes state.** A wrong or missing event edge produces a
  stale projection; a wrong command edge produces an unmade decision. The direction that was left
  invisible is the higher-consequence one.
- **New: an end-to-end port contract becomes checkable.** With all four tables, an EP command an
  extension *issues* and an EP command the port *accepts* are two rows that can be joined by name.
  A dangling command edge across a plugin boundary becomes a finding rather than a runtime no-op.
  (The check itself is cross-plugin — see §7, out of scope here.)

## §3 — The shape: one table per mapping function

Four functions, four tables. Each keyed by the **protocol name** — the name on the wire at the
port — which is the invariant the two existing tables already share and what lets the halves of an
edge join:

```
                    EP side                                Extension side
  events   publishedEvents  {name, fromEventTypes}  →  handledEvents   {name, toCommandTypes}
  commands acceptedCommands {name, toCommandTypes}  ←  issuedCommands  {name, fromEventTypes}
```

- **`issuedCommands`** on `ExtensionMapping.Mapping`, read off the extension's `mapOutgoingEvent`.
  Keyed by the EP command published, valued by the Delegate events producing it. Mirrors
  `publishedEvents` exactly — same many-to-one shape, same reason.
- **`acceptedCommands`** on `ExtensionPointMapping.Mapping`, read off `mapIncomingCommand`. Keyed
  by the EP command arriving, valued by the Delegate commands it routes to. Mirrors
  `handledEvents` exactly.

**`handledEvents` stays as it is.** Its `PublishExtensionPointCommand` arms are an
event→EP-command edge whose two endpoints are in different vocabularies, so keying it by protocol
name is ambiguous either way. Rather than move those rows or invent a third vocabulary in one
array, keep the rule "one table per function" and document the union: everything that issues EP
command `X` is `issuedCommands[X]` plus the `handledEvents` rows whose `toCommandTypes` contain
`X`. Changing `handledEvents`'s content would also break a consumer already reading it.

## §4 — The PPX work

### 4.1 Two new sides

`type side = Published | Handled` gains `Accepted | Issued`, and `target_of_action` gains:

```
| Accepted, "PublishCommand"              -> follow (nth_of_tuple 1) "the routed command"
| Issued,   "PublishExtensionPointCommand" -> follow (nth_of_tuple 1) "the published command"
```

`HandleDirective` stays `None` on all four sides (a local side effect routes nothing).
`ForwardCommand` stays `Unfollowable` on both new sides — it carries opaque JSON on the extension
side, and on the EP side `PluginExtensionPoint_Plugin` already routes it to a directive, which
reads as no edge and is correct.

### 4.2 Split side detection from function selection

`walk_module_expr` currently picks one binding and derives one table. It must instead decide the
side once, then derive both of that side's tables:

- `mapIncomingEvent` present → extension → `derive_handled` (from `mapIncomingEvent`) **and**
  `derive_issued` (from `mapOutgoingEvent`, `None` ⇒ no rows).
- else `mapIncomingCommand` or `mapOutgoingEvent` present → extension point → `derive_published`
  **and** `derive_accepted`.

The file-level EP path
([ReventlessPpx.ml:864-875](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L864-L875))
appends `derive_accepted` beside `derive_published` on the same filename predicate.

### 4.3 Prerequisite: the walk must follow a `let`-bound action array

This is the one change that is not mechanical, and it is a **latent correctness bug in the
existing derivation**, not new work the new sides invent.

`walk_body`'s `Pexp_apply` case keeps only arguments that are a lambda, a call, or a literal
([TranslationTable.ml:143-154](../../packages/reventless-ppx/src/ppx/TranslationTable.ml#L143-L154)).
A plain identifier is treated as data and **silently dropped**. In `PluginExtensionPoint_Plugin`'s
`ConnectPlugin` arm:

```rescript
let reportAction = if protocolErrors->Array.length > 0 {
  [PublishCommand(Plugin.name(id), Delegate.ReportIncompatibility(pluginDefinition))]
} else { [] }
Array.concat([PublishCommand(Plugin.name(id), Delegate.Connect(pluginDefinition))], reportAction)
```

the derivation would emit `ConnectPlugin → Connect` and lose `→ ReportIncompatibility` without a
word — the precise failure the first plan's §3 promised was impossible ("*no edge* and *did not
look* never read alike"). It does not bite today only because no `mapOutgoingEvent` arm in the
repo is written this way; turning on `mapIncomingCommand` hits it on the first file.

**Fix:** thread an environment through `walk_body`. `Pexp_let` binds `name ↦ expr` before
recurring into the continuation; a `Pexp_ident` argument in `Pexp_apply` resolves through it and
is walked; an identifier that resolves to nothing raises `Unfollowable` naming it. Do this
**first, as its own commit**, so the fix to the shipped table is separable from the new sides.

### 4.4 Errors and the escape hatch

Unchanged in kind: an unreadable arm fails the build naming itself and the table, and a file that
declares `acceptedCommands` / `issuedCommands` by hand keeps them. `report ~what` already
parameterises the message on the table name, so both new tables get the existing wording for free.

## §5 — The `Plugin_Structure` work

### 5.1 Name checks (both new tables)

`translationTableFailures` and `handledTableFailures` are already the two shapes needed; generalise
each over its name lists rather than writing two more:

- `acceptedCommands`: every `name` is a real EP `command` variant; every `toCommandTypes` entry is
  a real `Delegate.command` variant. Raises, like its mirror.
- `issuedCommands`: every `name` is a real EP `command` variant; every `fromEventTypes` entry is a
  real `Delegate.event` variant. Raises.

Both need `M.ExtensionPoint.commandSchema`, which both module types already expose.

### 5.2 Dead inbound surface (warning)

Mirror of [Plugin_Structure.res:1482-1491](../../reventless/core/src/plugin/component/Plugin_Structure.res#L1482-L1491):
an EP `command` variant that no `acceptedCommands` row names is warned as dead inbound protocol
surface. Expect this to fire on first run the way `PluginReconnected` did — `RegisterUiFragment`
is `[]` in the Plugin mapping and handled in the UiFragment mapping, so the check must union the
tables of all mappings sharing one EP *before* judging, which the `epByName` grouping already does
for the other lists.

### 5.3 Probe: EP side only

`acceptedCommands` gets the mirror probe — one synthesised EP command per constructor through the
author's own `mapIncomingCommand`, observing `PublishCommand`. Cheaper than the event probe: the
signature takes no `queryEngine`, so `probeQueryEngine` is not needed.

`issuedCommands` gets **no probe**, matching `handledEvents`, which has none either. `Plugin_Structure`
sees an extension only compiled, and the probe would need a `pluginDefinition` stand-in for
`mapOutgoingEvent`'s fourth parameter. Name checks only; note it in the code comment so the
asymmetry reads as a decision.

### 5.4 Emission and qualification

Beside the existing tables, with the same qualifiers: an EP command name is EP-qualified (it is
protocol), a Delegate command or event is plugin-qualified. `acceptedCommands` unions across
mappings sharing one EP, exactly as `epPublished` does.

## §6 — Vocabulary and the wire

`Plugin.res` gains `acceptedCommandDef {name, toCommandTypes}` on `extensionPointDef` and
`issuedCommandDef {name, fromEventTypes}` on `extensionDef` — both `js_nullable` per the
`commandTypes` precedent, always written, read with `->Option.getOr([])`. `Platform_ExtensionPointDef`
and `Platform_ExtensionDef` gain the fields in the SDL, with
`Platform_AcceptedCommandDef` / `Platform_IssuedCommandDef` beside their two siblings; refresh the
GraphQL goldens in the same commit.

**Two more fields on a persisted definition.** Every persisted plugin definition must be re-emitted
before a consumer can read them as present, and a required-field mistake wedges registration
silently. Sequence with `plugin-definition-schema-evolution-guards.md`, not separately.

## §7 — Out of scope

- **The cross-plugin join** (§2's fourth bullet). `Plugin_Structure` is per-plugin; checking that a
  command one plugin issues is one another plugin accepts belongs where both structures are known.
  Its own plan — `port-contract-cross-plugin-join.md` — once the tables exist.
- **Moving `handledEvents`' EP-command rows** (§3). Deliberately not done.
- **Removing the dead inbound surface §5.2 finds.** Removing a variant from a published protocol
  breaks a subscriber compiled against it — a warning here, a separate change there, exactly as
  `PluginReconnected` was left.

## §8 — Order of work

1. §4.3 alone — the `let`-bound-ident fix to the existing walk, with a PPX test that fails before
   it. Verifiable against the shipped tables; no new vocabulary.
2. §4.1 + §4.2 — the two new sides and the split dispatch, with PPX tests mirroring the existing
   ones (many-to-one, fan-out, a swallowing arm, an unreadable arm, the hand-written hatch).
3. §6 vocabulary + §5 checks and emission, goldens refreshed.
4. Sweep: the framework's three ports, the six example mappings and six extensions, and the GWT /
   local fixtures. The examples are all `[]` / `None`, so the real surface is the two lifecycle
   mappings — `PluginExtensionPoint_Plugin`'s `ConnectPlugin` arm is the one to watch, and it is
   the reason step 1 comes first.

## §9 — Risks

- **Every inline mapping fixture must satisfy two more module-type fields.** The nested walk
  derives them, so this is silent where the arms are readable and a build error where they are
  not. The GWT fixtures in `DelegateGwtTest` / `FlowCrossPluginGwtTest` are the population to
  check; a fixture with an unreadable arm needs a hand-written line, not a rewrite.
- **§4.3 changes what the shipped `publishedEvents` derives.** That is the point — a table that
  gains an edge it should always have had — but it is a behaviour change to a field consumers
  already read, so land it visibly rather than folded into the new work.
- **PPX binary/source lockstep**, per the first plan's §6: this repo builds the PPX from source,
  an external consumer on an older published binary gets no table (a missing field, not a wrong
  one). Republish `reventless-ppx` in lockstep.
