# Plan: an AutomationSlice cannot read an aggregate it is allowed to name

**Date:** 2026-09-01<br/>
**Status:** ✅ **DONE 2026-09-01.** The falsifier resolved in favour of the cheap answer, and the
change was made.

`AutomationSlice_Callback`'s `phase1` already decodes the envelope —
`json->Message.decode(Message.contextSchema)`, where `context = {id, meta}` — and uses only
`context.meta.service`, discarding `context.id` one line before dispatch. So the value was present at
the dispatch point all along: **a signature change, not a dispatch change**, exactly as §Falsifier
hoped rather than feared.

`Mapping.collect` and `MappingImpl.collect` now take `~sourceId: string`, `phase1` passes
`context.id`, and every existing mapping gained `~sourceId as _`. A regression test asserts the
envelope's id reaches `collect` against a fixture whose envelope id (`"env-a1"`) is deliberately not
any value in the payload; passing `""` instead of `context.id` turns it red.

The documentation qualification added while this was open is deleted — it described a limit that no
longer exists. What stays is the note that an `OutboundTranslationSlice` is still the better shape
for a pure relay, which is about item completion rather than about ids.

## The gap

`AutomationSlice` supports per-source mappings, and the module doc says so plainly:

> An AutomationSlice can declare per-source mappings that consume Aggregate events alongside the
> slice's own DcbEventLog events.

But the mapping's collect is

```rescript
let collect: (sourceEvent, context) => array<(string, todoItem)>
```

and `context` is `{environment, platformName, pluginName, sliceName}`. **There is no entity id.** An
aggregate's event payload generally does not repeat the id that addressed it — `Registered({email,
address})` is the canonical case — so a mapping over an aggregate source cannot say *which* entity
its todo item is for, and cannot build a per-entity todo key.

The result is not a compile error. The mapping is declarable, it type-checks, and it produces todo
rows that are wrong or unkeyable. The support is real only for sources whose events happen to name
their own subject, which in practice means DCB events.

*[2026-09-01] The doc quoted above now carries that qualification, so this section describes the
signature, not a claim still being made.*

## The framework already solved this next door

`OutboundTranslationSlice.Translation.collect` takes `~sourceId`, and its doc explains exactly this
case:

> an Aggregate's event generally does not [name its subject], because the aggregate id is what
> addressed it in the first place. Without this the outbound item for `Registered({email, address})`
> would have no way to say *which customer* it is for.

`ReadModel`'s mapping has the same thing in record form (`{event, id, _}`).

So two of the three components that consume events get the id and one does not, and the one that does
not is the one whose doc advertises aggregate sources hardest.

## Cost of working around it

A plugin that wants "relay an aggregate announcement into a DCB slice" has to use an
`OutboundTranslationSlice` with no external system, whose `translate` is a pure pass-through. That
works — the item completes on the publish, which is arguably better than an automation's
resolve-on-event — but it is an anti-corruption component used for something inside the plugin, it
draws no external box, and a reader has to be told why it is not an automation.

## The change

1. Widen `MappingImpl.collect` / `Mapping.collect` to `(sourceEvent, ~sourceId: string, context)`, or
   put `sourceId` on `context`. The latter is a smaller diff and needs no call-site change beyond the
   record, but it makes an *event-scoped* value look ambient — `context` is documented as
   "deployment context" and is deliberately narrow. Prefer the labelled argument.
2. Every existing mapping gains `~sourceId as _`. There are few.
3. Say in `AutomationSlice`'s doc which sources need it and why, the way
   `OutboundTranslationSlice`'s does.

## Falsifier

If a source id is not derivable at dispatch for aggregate sources the way it is for the outbound
collector, this is not a signature change but a dispatch change, and the cost is different. Check
`AutomationSlice_Callback`'s decode path before committing to the shape above — the outbound
collector clearly has the envelope, so the value exists; what is unverified is that the automation's
dispatcher holds it at the same point.
