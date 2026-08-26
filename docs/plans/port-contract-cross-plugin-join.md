# Plan: joining the two halves of a port contract across plugins

**Status.** Proposed 2026-08-27. Depends on `port-translation-table-command-direction.md` — the
join needs all four tables to exist before it has anything to join.

**Goal.** Once both sides of a port publish their translation tables, an edge that leaves one
plugin and lands nowhere in another becomes checkable. Say where that check runs, what it does
about a finding, and what it deliberately does not do.

---

## §1 — Should we? Yes, and the framework already half-does it

The `ConnectPlugin` handshake already asks this exact question and answers it with a proxy.
`Compat.validateProtocol` ([Compat.res:56-101](../../reventless/interop/src/Compat.res#L56-L101))
compares one `commandVersion` and one `eventVersion` per extension point — a single semver
standing in for "your idea of my protocol matches mine". On mismatch the host emits
`ReportIncompatibility`, the Plugin aggregate records `IncompatiblePluginDetected`, and **the
connection still proceeds** ([PluginExtensionPoint_Plugin.res:183-210](../../reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res#L183-L210)).

So the seam, the vocabulary and the non-fatal policy all exist. What is missing is resolution: a
version number cannot say *which* edge broke, and a correct-looking bump can hide a routing
defect entirely. The tables name constructors the compiler checked, so the join answers per edge.

**Versions and tables are complementary — keep both.** A table names constructors, so it catches
**routing** defects: a command that lands nowhere, an event nobody publishes. It says nothing
about payload shape, so a new required field on a command is invisible to it — which is exactly
what the semver catches. Neither subsumes the other; do not fold `validateProtocol` into this.

## §2 — The two checks worth making

Four dangling-edge shapes exist; only two are defects.

| Finding | Verdict |
|---|---|
| Extension issues EP command `X`; owner's `acceptedCommands` has no `X` | **Defect.** The sender got no error and believes it commanded something. |
| Extension handles EP event `Y`; owner's `publishedEvents` has no `Y` | **Defect.** The subscriber routes a fact that never arrives. |
| EP publishes `Y`; no extension handles it | Not a defect — a port may legitimately have no subscriber yet. |
| EP accepts `X`; no extension issues it | Not a defect cross-plugin; already warned intra-plugin as dead inbound surface. |

The join key needs no new naming: §5.4 of the tables plan qualifies every EP-side name by the
dotted EP name on both sides, so the two halves are directly comparable strings.

## §3 — Where it runs: two tiers, and one place it must not

### Tier A — plugin composition (build time)

Where a platform composes plugins statically — every example shop, and the common monorepo case —
`Platform.Plugin.make` sees every plugin's structure at assembly. Run the join there, reusing
`reportTranslationTables`'s warn/throw shape one level up from
[Plugin_Structure.res:328-342](../../reventless/core/src/plugin/component/Plugin_Structure.res#L328-L342).

Cheapest possible: no wire change, no new component, no offload resolution, and it fails before
anything deploys. This is where most findings will surface.

### Tier B — the plugin registry (runtime)

Independently deployed plugins never meet at assembly, which is the case Tier A cannot cover.
They do meet in the Plugins read model: `PluginsProjection` stores each connected plugin's
`structure` as wire JSON ([PluginsProjection.res:57-67](../../reventless/core/src/plugin/lifecycle/PluginsProjection.res#L57-L67)),
and `Platform_ComponentDefinitionsApi` already reads it back and resolves the offload sentinel.

Put the join there, as a **derived field on the existing admin read path** — not a new aggregate,
slice or event. It needs no persisted state of its own: both inputs are already stored, and the
answer changes whenever either side reconnects, so computing it on read is both simpler and more
correct than recording it.

### Not in the handshake

Tempting, since `validateProtocol` lives there, but `mapIncomingCommand` is synchronous, takes no
`queryEngine`, and the connecting definition's `structure` is
`option<Offload.payload<pluginStructure>>` — potentially an `{$offload}` sentinel needing an async
store read. The owner's tables are in another plugin's registry row, which the arm cannot reach
either. Stretching the arm to do this would put an I/O dependency inside a mapping. Leave the
handshake doing the version check it can do synchronously.

## §4 — What a finding does: reports, never refuses

Keep the existing policy exactly. A dangling edge at connect time is very often deploy ordering —
an extension coming up before the owner it targets, or an additive protocol change landing on one
side first. Refusing the connection would make ordinary rollouts unbootstrappable and would be a
harsher response than the framework gives an actual version incompatibility today.

- Tier A: warn, matching how the intra-plugin dead-surface checks report. Reserve throwing for a
  malformed table, which the intra-plugin name checks already own.
- Tier B: report as data on the read path. No new event, no `IncompatiblePluginDetected` overload —
  that event means "declared versions disagree", and widening it would make an existing signal
  ambiguous.

## §5 — The trap: `Option.getOr([])` erases what the join needs

All four tables are `js_nullable` per the `commandTypes` precedent, and every current reader does
`->Option.getOr([])`. For the join that is wrong in a way that produces a wall of false findings on
first run:

- `None` — a definition persisted before the field existed, or a table the PPX refused to derive
  and nobody wrote by hand — means **unknown**.
- `Some([])` means **genuinely nothing**.

Only the second can support a finding. Treating `None` as `[]` flags every plugin registered
before these fields shipped as issuing and accepting nothing, and re-runs the first plan's own
principle in reverse: *no edge* and *did not look* must not read alike. The join reads the raw
option on all four tables; a `None` on either side skips the pair and says so.

This also handles the `ForwardCommand` case by construction: an arm carrying opaque JSON is
`Unfollowable`, so its plugin either hand-wrote the table or has none — and a hand-written table
is a claim the join can check, while an absent one correctly reads as unknown.

## §6 — Order of work

1. Tier A. Self-contained, no wire or storage implications, and it exercises the join logic where
   both inputs are in hand and typed.
2. Tier B, reusing Tier A's join function against the resolved registry structures. Sequence
   behind the re-emission of persisted definitions — until those carry the new fields, Tier B
   correctly reports `None` everywhere and finds nothing.

## §7 — Out of scope

- **Replacing or extending `validateProtocol`** (§1). It answers a different question.
- **A new lifecycle event for a dangling edge** (§4).
- **Payload-shape comparison across the port.** The tables carry constructor names only; comparing
  field shapes between two independently compiled schemas is a different problem and belongs with
  the version policy, not here.
