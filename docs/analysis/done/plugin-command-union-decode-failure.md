# The Plugin aggregate decodes two of its eight commands

**Date:** 2026-08-18
**Status:** Resolved 2026-08-21 — the upstream cause is fixed in sury `11.0.0-rc.2`
([DZakh/sury#392](https://github.com/DZakh/sury/issues/392)), and the repo is pinned
there. Found while verifying step 0 of
[admin-structure-derived-from-specs.md](../plans/done/admin-structure-derived-from-specs.md);
neither caused nor fixed by it.

Option 1 below (reorder so a union-bearing payload leads) is what shipped, and it is
still in place — it is wire-compatible and costs nothing to keep. The reachability
sweep that enforces it now only recognises the older codegen shape; see
[union-reachability-guard-rc2-shape.md](../plans/Backlog/union-reachability-guard-rc2-shape.md).
**Where it bites:** every local platform, and AWS equally — the affected schemas live in
`reventless-core` and `reventless-infra` and are shared by both, though only local was
driven. Three unions are broken today, not one; see *Where else it already bites*.

An analysis rather than a plan: the cause is upstream of this repo, so what to do
about it is a decision, not a task list.

---

## What happens

Start the hybrid example on a memory backend and both plugins fail to connect:

```
ERROR decode failed: {"id":"Catalog", … "command":{"TAG":"Connect","_0":{…}}} err=unknown
  comp=CommandTopic(Plugin)
```

`Platform_Plugins` is then empty — no plugin ever reaches the admin's read model, so
nothing downstream has a plugin row to show or act on.

The same silence swallows admin commands. A `Platform_Plugin_Deactivate` mutation
answers `CommandAccepted` and then:

```
INFO  Platform_Plugin_Deactivate(Catalog@1.0.0-alpha.214): dispatching to aggregate
ERROR decode failed: {… "command":{"TAG":"Deactivate","_0":"1.0.0-alpha.214"}} err=unknown
```

Accepted, logged, dropped. The caller is told it worked.

## The cause

`PluginSpec.command` has eight variants. Parsing each against
`PluginSpec.commandSchema`:

| Variant | | |
|---|---|---|
| `Heartbeat(version)` | 1st | OK |
| `Redetect(version)` | 2nd | OK |
| `Connect(pluginDefinition)` | 3rd | **fails** |
| `Disconnect(version)` | 4th | **fails** |
| `Activate(version)` | 5th | **fails** |
| `Deactivate(version)` | 6th | **fails** |
| `ReportIncompatibility(pluginDefinition)` | 7th | **fails** |
| `Retire(version)` | 8th | **fails** |

`Disconnect` and `Heartbeat` have identical shapes (`{TAG, _0: string}`) and disagree,
so it is not the payload. The same `pluginDefinition` parses fine on its own against
the same `Plugin.pluginDefinitionSchema` — it is only inside the union that it breaks,
and it takes its successors with it.

The reason is visible in the parser sury generates for the union. It collapses a
**contiguous run of two or more statically-checkable object variants** into one inner
dispatch block, and guards that block with "is this an object?" rather than with the
TAGs the block actually handles:

```js
i => { for(;;) {
  if (typeof i === "object" && i && !Array.isArray(i)) {   // guard omits the TAG
    for(;;) {
      if (i["TAG"] === "Heartbeat") { … break }
      if (i["TAG"] === "Redetect")  { … break }
      e[2](i)                        // ← every other object throws here
    };
    break                            // ← and this exits the outer dispatch
  }
  if (… && i["TAG"] === "Connect")    { … }   // unreachable
  if (… && i["TAG"] === "Disconnect") { … }   // unreachable
  …
} }
```

Every object entering the parser is captured by the grouped block. A TAG the group
does not know hits its fall-through throw, and the trailing `break` means the branches
below are dead code. So the rule is:

> A grouped run of ≥2 variants that is **not the last group in the union** strands
> every variant after it.

`Heartbeat` and `Redetect` both carry `version` (a bare string), so they group;
`Connect` carries a union-bearing payload and cannot join them; the group is therefore
not last, and variants 3–8 are unreachable. The position of the *first union-bearing
payload* is what decides where the stranding starts — not the payload itself.

Two things follow that are easy to get wrong:

- **The trigger is wider than "a nested union".** An `option` or nullable field is a
  union in sury, so any record payload with one qualifies. And the leading run need not
  be uniform — two variants with *different* plain record payloads still group.
  Payload-less variants (bare literals) do **not** group: they serialise as strings,
  not objects, so they never enter the object-guarded block.
- **Leading is safe; third-or-later is not.** A union-bearing payload at position 1 or 2
  leaves the whole union working, because it gets its own TAG-guarded branch and the
  group that follows it is last. At position 3, 4, or even *last of five*, that variant
  and all successors fail.

Nothing here is specific to `PluginSpec`. This is a sury codegen regression, and any
`@schema` variant type whose first union-bearing payload sits third or later is exposed.

### Where else it already bites

A sweep of the 109 tagged-union schemas compiled in this repo — detecting a non-final
grouped block in the generated parser, each hit confirmed by round-trip — finds three,
not one. The sweep is not exhaustive: 25 modules (all test files, which need Jest
globals to import) could not be loaded.

| Schema | Reachable | Stranded |
|---|---|---|
| `PluginSpec.commandSchema` | `Heartbeat`, `Redetect` | `Connect`, `Disconnect`, `Activate`, `Deactivate`, `ReportIncompatibility`, `Retire` |
| `PluginExtensionPointSpec.directiveSchema` | `CreateDisconnectSchedule`, `DeleteDisconnectSchedule` | `DoConnectPlugin`, `DoDisconnectPlugin`, `ForwardCommand` |
| hybrid catalog `Products.consumedEventSchema` | `ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged` | `ProductPriceChanged`, `ProductImageChanged`, `ProductArchived`, `ProductUnarchived`, `ProductDiscontinued` |

The second is arguably the more serious: it sits in `reventless-infra`, and
`DoConnectPlugin` is the handshake directive itself. The third is a projection silently
dropping five of its eight event types.

`PluginSpec.eventSchema` is **not** affected, and its shape shows why the rule is about
grouping rather than richness: its six consecutive `pluginDefinition` variants form a
group, but that group is last, so nothing is stranded.

### Which sury versions

The grouped-loop codegen is absent from every published bundle through
`11.0.0-alpha.11` and present in `11.0.0-rc.0` and `11.0.0-rc.1` (the pinned version).
The optimization — and this failure mode with it — landed in **`rc.0`**.

Fixed in **`11.0.0-rc.2`** (2026-08-20), which is where the repo is now pinned. At the
time of writing `rc.1` was the newest published version, so there was nothing to move
forward to — and moving backward was not a version pin: the schema-building API changed
at both the alpha→rc boundary (`$schema`/`s.m` vs `schema`/`s.matches`) and the v10→v11
boundary, and sury-ppx emits against the v11 API — so a downgrade would have been a
codegen change across every `@schema` type in the repo, onto releases carrying their own
known regressions.

Reported upstream as [DZakh/sury#392](https://github.com/DZakh/sury/issues/392)
(filed 2026-08-18, closed 2026-08-20); the source text is in
[sury-union-regression-issue.md](sury-union-regression-issue.md). sury's tracker shows a
cluster of other regressions from the same rc line
([#347](https://github.com/DZakh/sury/issues/347) open, #351/#369 closed) — #347 is the
closest neighbour and may share a cause, but it is on the encode path.

## Why nothing caught it

Two failures compound.

**The error is thrown away.** `CommandTopic_Callback` reads the reason via
`JsExn.message`, and sury raises a ReScript exception that is not a `JsExn` — so
every one of these logs `err=unknown`. A decode failure that named the offending
variant would have been diagnosable from the first boot log.

**The failure is silent to the caller.** The GraphQL mutation resolves to
`CommandAccepted` because acceptance means *enqueued*; the decode happens downstream
on the command topic, where nothing reports back. `eventCount: 0` is the only tell,
and it is also what a legitimately idempotent command returns.

**The tests only ever encode.** Every test touching `PluginSpec.commandSchema` calls
`Message.encode` — `MessageTest` even builds a full `Connect` and encodes it, and
encoding works fine for all eight variants. Nothing decodes a command, so the one
direction that is broken is the one direction untested. (`PluginSpec.eventSchema` *is*
decoded, by `PluginLifecycleCorpusTest` and `PluginEventDecodeTest` — and it is the
schema that happens to be unaffected.)

That is the gap worth closing whatever is done about the cause: a command union that
cannot decode its own constructors is a property worth asserting per spec, not per
aggregate. The sweep used here is cheap enough to be that assertion — it needs no
fixture values, only the generated parser, and it caught all three cases.

## What it means for the work around it

The derive-from-specs plan's step 0 question — does the missing `_0` argument break
the admin row actions — is answered independently and is **yes**: the mutation is
rejected at GraphQL validation, before any of this. Fixing the published argument
schema is necessary and was worth doing. It is not sufficient: with `_0` supplied,
the command now reaches the topic and is dropped there instead.

The consequence for verification is what matters. Any step whose check is "drive it
in a running shell" cannot be checked end to end until this is fixed — there are no
plugin rows to drive. Metadata-level verification (what `Platform_ComponentDefinitions`
publishes) is unaffected, and is what those steps were verified against.

## Options

1. **Reorder the variants so a union-bearing payload comes _first_.** Verified against
   the real schemas: `Connect`/`ReportIncompatibility` moved to the front makes all
   eight parse. Note this is the *opposite* of the intuitive fix — moving them last
   leaves the six-variant `version` run leading and non-final, and they still fail.
   Cheapest, and a workaround that will be forgotten and re-broken by the next
   variant added.
2. **Wait for the upstream fix.** Filed as
   [DZakh/sury#392](https://github.com/DZakh/sury/issues/392). The only option that
   removes the bug rather than dodging it, but not on our clock — and with no version to
   bump to meanwhile, since `rc.1` was then the newest published and downgrading is a
   codegen change, not a pin (see *Which sury versions*). **This is what happened:** the
   fix landed in `rc.2` two days after filing, and option 1 carried the gap.
3. **Flatten `pluginDefinition`'s unions** — resolve the offload envelope before
   decode rather than modelling it in the schema. Largest change, and it removes the
   shape rather than working around it. Does not help `directiveSchema` or
   `Products.consumedEventSchema`, which are broken by different payloads.

Whichever: **log the decode reason properly first, and add the sweep as a test.**

The logging is three lines in `CommandTopic_Callback`, independent of the fix, and
without it the next occurrence is as opaque as this one. The error sury raises is a
`SuryError` carrying `RE_EXN_ID: "S.Exn"` — a JS `Error` instance, but not a ReScript
`JsExn`, which is why `JsExn.fromException` yields `None` and the message is replaced
by `"unknown"`. The full text (`Expected { TAG: "Heartbeat"; … }`) is sitting on the
exception the whole time.

The sweep matters more than any single fix: option 1 is per-union and will drift, and
the two cases outside `PluginSpec` show the exposure is not where anyone was looking.
