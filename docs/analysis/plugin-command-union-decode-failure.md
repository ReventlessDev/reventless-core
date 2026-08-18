# The Plugin aggregate decodes two of its eight commands

**Date:** 2026-08-18
**Status:** Open — found while verifying step 0 of
[admin-structure-derived-from-specs.md](../plans/admin-structure-derived-from-specs.md);
neither caused nor fixed by it.
**Where it bites:** every local platform. Almost certainly AWS too, though only local
was driven.

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
so it is not the payload — it is the position. Everything at and after the third
variant fails.

The third variant is the first whose payload contains a **nested union**.
`pluginDefinition` has three: `apiSchemaFragment` (offload envelope | inline | null),
`structure` (the same), and `kind` (a literal union). Minimal repro, plain sury
11.0.0-rc.1, no Reventless code:

```js
const mk = (payload) => S.union([
  S.$schema(s => ({ TAG: "One",   _0: s.m(S.string) })),
  S.$schema(s => ({ TAG: "Two",   _0: s.m(S.string) })),
  S.$schema(s => ({ TAG: "Three", _0: s.m(payload) })),
  S.$schema(s => ({ TAG: "Four",  _0: s.m(S.string) })),
])

// payload = S.schema({ a: S.string })                     → all four parse
// payload = S.schema({ a: S.string, kind: S.union([…]) })  → One, Two parse;
//                                                            Three, Four fail
```

The same `pluginDefinition` parses fine on its own, against the same
`Plugin.pluginDefinitionSchema` — it is only inside the union that it breaks, and it
takes its successors with it.

So: a **sury union whose variant payload contains a union** stops parsing at that
variant, and every later variant becomes unreachable. Nothing about this is specific
to `PluginSpec`; any `@schema type command` with a rich payload mid-list is exposed,
which makes it a framework-wide exposure rather than one component's bug.

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

The tests do not cover it because they exercise `decide` directly, against ReScript
values that never round-trip through the schema. That is the gap worth closing
whatever is done about the cause: a command union that cannot decode its own
constructors is a property worth asserting per spec, not per aggregate.

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

1. **Reorder the variants** so every rich payload sits last. Cheapest, and a
   workaround that will be forgotten and re-broken by the next variant added.
2. **Pin or bump sury.** 11.0.0-rc.1 is a release candidate; check whether a later
   build fixes it, and report upstream if not. The minimal repro above is the report.
3. **Flatten `pluginDefinition`'s unions** — resolve the offload envelope before
   decode rather than modelling it in the schema. Largest change, and it removes the
   shape rather than working around it.

Whichever: **log the decode reason properly first.** It is three lines in
`CommandTopic_Callback`, it is independent of the fix, and without it the next
occurrence is as opaque as this one.
