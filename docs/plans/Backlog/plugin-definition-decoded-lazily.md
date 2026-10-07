# Plan: the Plugin aggregate stops decoding the full definition on every replay

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/plugin-definition-schema-evolution-guards.md](../done/plugin-definition-schema-evolution-guards.md) (its Phase 5 and the analysis's Option E) when it closed. Nothing is unknown; it waits on a value judgement about whether the CI guards are enough.<br/>
**Relates to:** [../../analysis/plugin-definition-schema-evolution-wedge.md](../../analysis/plugin-definition-schema-evolution-wedge.md) (options D and E)

---

## What is left

In plain words: every lifecycle event of the Plugin aggregate carries the plugin's whole
definition, and replay decodes all of it into a typed record — although `decide` / `evolve` in
`reventless/core/src/plugin/lifecycle/PluginBehavior.res` only read `version`, compare definitions
and carry them forward. So a field added to the definition's types can still break replay, and a
broken replay freezes that plugin's lifecycle.

The closed plan made that a red CI build instead of a frozen plugin (the frozen-payload corpus,
the `pluginDefinitionRequiredScalars.txt` golden list, scalar healing with a warning). What it
did not do:

1. **Lazy decode (option D).** Type the definition inside the event as opaque `JSON.t` and decode
   it only where it is read — the projection and the API. Replay then cannot fail on a metadata
   field; a bad payload degrades one plugin's manifest instead of its lifecycle.
2. **Stop persisting derived metadata (option E).** The definition is derived at deploy time; the
   event log is a registration ledger, not its natural home. The correct end state, with the
   largest reach. D is most of its benefit at a fraction of the cost.

## What is already settled

The one risk D carried — the idempotency branch in `decide` (`definition == def ? Ok([]) : …`)
comparing raw JSON — was measured against real stored payloads: an event written under an older
shape compares unequal **once**, causing one extra `VersionConnected` per plugin per schema
change, and equal afterwards. Comparing `decode(stored) == decode(incoming)` at that single branch
removes even that, keeping decode out of the replay path.

## The evidence to weigh

The gate was "does the guard fire often enough to be an irritation?". The golden list has changed
in 11 commits between 2026-08-01 and 2026-10-07 — each one a deliberate required-scalar addition
an author had to acknowledge. If those were one-minute edits, the guards suffice and this stays
here. If any of them meant a real migration or a confused author, schedule D.

## Done looks like

- `PluginSpec`'s events carry the definition as `JSON.t`; `PluginBehavior` decodes only at the
  idempotency branch.
- A redeploy with an unchanged definition emits **no** `VersionConnected`.
- The lifecycle corpus in `reventless/core/tests/fixtures/plugin-lifecycle/` still replays, and a
  deliberately undecodable definition degrades the projection, not the aggregate.
