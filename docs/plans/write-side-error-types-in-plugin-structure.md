# Plan: surface a write-side component's declared error types in the plugin structure

**Date:** 2026-08-08
**Status:** Proposed.
**Repos:** `reventless-core` only.

## Why

A write-side component declares three families of message type, not two. `Aggregate` and
`StateChangeSlice` each require a `Spec.errorSchema` beside `commandSchema` and `eventSchema`, and
it is load-bearing at runtime: `Aggregate_Callback.res:84` and `StateChangeSlice_Callback.res:429`
encode a rejected decision through it, and `CommandTopic_Helpers.res:16` documents `errorCode` as
"the variant tag of `Spec.errorSchema`". The declared errors are part of a component's contract in
the same sense its commands and events are — a caller has to handle them.

The structural surfaces do not reflect that, and they are inconsistent about it in two different
directions:

| Surface | commands | events | errors |
| --- | --- | --- | --- |
| Deployed-schema hook, aggregate branch (`Plugin_Builder.res:432-435`) | yes | yes | **yes** |
| Deployed-schema hook, state-change-slice branch (`Plugin_Builder.res:526-536`) | yes | yes | **no** |
| Static plugin def, `writableDef` (`spec/src/components/Plugin.res:292-305`) | yes | yes | **no** |
| SDL `Platform_WriteSideDef` (`Platform_ComponentDefinitionsApi.res:23`) | yes | yes | **no** |

So an aggregate's error types are announced at deploy time and then dropped from every structural
read, and a state-change slice's are not announced anywhere at all — even though
`Plugin_BuiltHook.res:72` already declares `errorTypes` on the shared schema type, and the
state-change-slice branch's own comment claims it surfaces its types "at parity with aggregates,
read models, and routing slices".

The result is that a structural consumer can enumerate what a component accepts and what it emits,
but not what it can refuse. That is a gap in the contract description, not a display concern: the
refusal cases are the part of a write-side component's surface a caller most needs to know about,
and they are the only part not currently retrievable.

## Change

1. **Close the hook asymmetry.** The state-change-slice entry in `Plugin_Builder.res` gains
   `errorTypes: extractTypes(Scs.Spec.errorSchema)`, matching the aggregate branch twelve lines up.
   One line, and it makes the surrounding comment true.

2. **`Reventless.Plugin.writableDef` gains `errors`.** Mirroring `events: array<eventDef>`, with an
   `errorDef` modelled on `eventDef` (`{name, schema, references}` — the same walk, so a consumer
   reading an error's shape uses the code path it already uses for an event). If the field-level
   detail proves unwanted, the fallback is `array<string>` at parity with `producedEventTypes`;
   decide before implementing rather than shipping both.

3. **`Plugin_Structure` populates it** through an `extractErrorDefs` beside `extractEventDefs`
   (`Plugin_Structure.res:378-382`), applied in both the `stateChangeDefs` and `aggregateDefs`
   builders.

4. **The SDL exposes it.** A `Platform_ErrorDef` type plus `errors` on `Platform_WriteSideDef` in
   `Platform_ComponentDefinitionsApi.res:23`. That type is shared by both admin APIs that serve
   write-side components, so both gain the field from one edit.

## The one decision to settle first

**Required array, or nullable list?** Both precedents live in the code and they disagree:

- `writableDef.events` was added as a **required** array, and its docstring gives the reason:
  "Required like the other write-side arrays; `[]` when there are none. The structure is re-derived
  on every build/deploy, so no persisted-data back-compat shim is needed."
- `Platform_PluginStructureEntry` makes `extensionPoints` / `requiredStores` **nullable** lists, and
  its comment gives the opposite reason: "a structure written by an older deploy sends null, and
  null is the honest answer — an empty list would claim the plugin has no extension points when the
  truth is that the deployment cannot say."

**Recommendation: follow `events`** — a required array on `writableDef`, a required list in the SDL.
The two comments are not actually in conflict; they describe different lifetimes. `events` is right
that the static structure is re-derived on every build, so no *persisted* structure predates the
field. But that argument only holds if it is still true, and it is the one thing to verify before
writing the field: if any consumer reads a structure persisted by an older deploy, the honest answer
there is null and this flips. Check it, record the answer here, then implement.

Note also that a sury field cannot be both absent-tolerant and JSON-encodable, so "nullable" here
means an explicit `T | null`, not an optional field — the same shape `consistencyRead` uses via
`stringOptionSchema`.

## Non-goals

- **No runtime change.** How errors are raised, encoded, or returned is untouched; this only
  describes what a component declares.
- **No new extraction machinery.** `Spec.errorSchema` is already required on both write-side kinds
  and already walked by `extractTypes` in the aggregate branch. Nothing new is being introduced —
  three of the four surfaces above are simply not carrying a value the fourth already computes.
- **No change to the read-side defs.** A read model or state-view slice declares no errors.

## Acceptance

- Both write-side kinds surface their declared error types on the deployed-schema hook; the
  aggregate/state-change-slice asymmetry is gone and a test pins it for both kinds.
- `writableDef` carries a component's errors, populated for aggregates and state-change slices, and
  the SDL serves them through both admin APIs that use `Platform_WriteSideDef`.
- A component that declares no error variants reports an empty list, and that is distinguishable
  from a structure that cannot say — per whichever way the decision above lands, stated explicitly
  rather than left to a reader's inference.
- `PluginStructureTest` covers errors alongside the command/event assertions it already makes.
- No change to any component's runtime behaviour; the existing callback tests pass untouched.
