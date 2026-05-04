# Plan: DCB CommandGenerator — Derive Envelope ID from Partition Tag

## Problem

DCB StateChangeSlice commands annotated with `@compositePartitionTag` (or any DCB
command whose envelope `id` is not also passed as an explicit `id` argument) fail
to decode at the slice boundary:

```
Couldn't decode command {"meta":{...},"command":{"TAG":"X",...}}:
SuryError: Failed parsing at ["id"]: Expected string, received undefined
  at Module.decodeCommand$p (.../Message.res.mjs:32)
  at EffectPrimitive.effect_instruction_i0 (.../StateChangeSlice_Builder.res.mjs:24)
```

`Message.toCommandSchema'` requires `{id, meta, command}` at the top level
(`Message.res:25-30`). The id schema is `Reventless.Id.String.schema`, which
rejects `undefined`. The slice builder calls `decodeCommand'` for every JSON it
pulls off the topic (`StateChangeSlice_Builder.res:17`), so a missing envelope
id silently drops every command of that type.

The id is sourced in `makeGenerateCommand`:

```rescript
// CommandGenerator_Callback.res:44
let id = payload.arguments.id
```

`payload.arguments` is whatever the resolver passed in. Two resolvers feed it:

- **In-memory** (`reventless-in-memory/.../CommandGeneratorResolvers_GraphQL.res:178`,
  `registerDcb`): finds the first field whose schema is tagged via `DcbTag.isTagged`
  and copies its value into `args["id"]`. For multi-tag composite-partition
  variants this picks one field arbitrarily and doesn't reflect the partition
  spec; for variants with no `@s.matches(DcbTag.string)` field at all it leaves
  `args["id"]` unset and `payload.arguments.id` becomes `undefined`.
- **AppSync** (`reventless-aws/.../AppSync_Resolver_Functions.res:832`,
  `invokeDcbMutation`): forwards `ctx.args` verbatim. Whatever the SDL doesn't
  declare is simply absent. `@compositePartitionTag` fields don't surface as a
  composite `id` because the SDL is generated from the schema's properties and
  there's no synthesis step.

Meanwhile the framework already knows how to derive a partition key value from
a command:

- `DcbTag.derivePartitionTag` (`reventless-spec/.../DcbTag.res:758`) returns
  `Simple` or `Composite` for any annotated schema.
- `DcbTag.extractTags` + `DcbTag.getCompositePartitionKeyValue` /
  `DcbTag.getPartitionTagValue` already build the value used by
  `StateChangeSlice_Callback` for `entityId` in command outcomes
  (`StateChangeSlice_Callback.res:70-75`).

So the slice itself derives a partition key for accepted-command reporting and
storage layout, but the message *envelope* id — which the decoder gates on —
ignores all of that and depends on the resolver getting it right per call site.
Two resolvers, two ad-hoc strategies, one of which doesn't cover composite
partition tags.

This makes `@compositePartitionTag` a documented framework feature that does
not work end-to-end without each caller manually forwarding a synthetic `id`
field in the mutation arguments.

## Fix

Derive the envelope id inside `makeGenerateCommand` itself when the component
kind is `StateChangeSlice` and `payload.arguments.id` is missing. Use the same
helpers the slice already uses, so the envelope id and the slice's partition
key derive from one source of truth.

This collapses the two resolver-side workarounds into one schema-driven
derivation that runs after the resolver and before the message envelope is
built, so every transport (in-memory direct dispatch, in-memory GraphQL,
AppSync→Lambda, future transports) gets correct behavior automatically.

### Step 1 — Derive id from schema in `makeGenerateCommand`

File: `reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res`

Replace the unconditional `let id = payload.arguments.id` (line 44) with a
schema-aware derivation when the component is a StateChangeSlice and no id was
supplied:

```rescript
let suppliedId = payload.arguments.id
let id = switch (componentKind, suppliedId->Js.Undefined.return->Js.Undefined.toOption) {
| (Aggregate, _) => suppliedId  // unchanged: aggregates require explicit id arg
| (StateChangeSlice, Some(id)) => id  // resolver supplied one (DcbTag.partition single-tag flow)
| (StateChangeSlice, None) =>
  // No supplied id — derive from the command's partition tag.
  // Preconditions (caller-side): commandJson is shaped so DcbTag.extractTagsFromJson
  // can read it. We have payload.arguments as JSON-shaped already.
  let argsJson =
    payload.arguments
    ->JSON.stringifyAny
    ->Option.flatMap(s => Some(s->JSON.parseOrThrow))
    ->Option.getOr(JSON.Null)
  // Reconstruct command JSON: {TAG: command, ...arguments}
  let commandJsonForTags = switch argsJson {
  | Object(d) =>
    let withTag = d->Dict.copy
    withTag->Dict.set("TAG", JSON.String(payload.command))
    JSON.Object(withTag)
  | _ => JSON.Null
  }
  let derived = Reventless.DcbTag.derivePartitionTag([
    (serviceName, "", commandSchema),
  ])
  switch derived {
  | Simple(pt) =>
    let tags = Reventless.DcbTag.extractTagsFromJson(commandSchema, commandJsonForTags)
    Reventless.DcbTag.getPartitionTagValue([{eventTypes: [], tags: ?Some(tags)}], pt)
    ->Option.getOr("")
  | Composite(spec) =>
    let tags = Reventless.DcbTag.extractTagsFromJson(commandSchema, commandJsonForTags)
    Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec)
  }
}
```

Notes:
- The Aggregate path is unchanged — aggregates inject `id: ID!` into the SDL
  and the resolver sets `args.id` from the GraphQL variable. They never hit
  the StateChangeSlice branch.
- The StateChangeSlice + `Some(id)` branch preserves the current
  single-`@partitionTag` flow handled by `registerDcb`'s id extraction, so
  existing aggregate-shape DCB commands keep working.
- The StateChangeSlice + `None` branch is the new behavior. It's a no-op for
  any command that already supplied an id, so adopting this is non-breaking
  for current call sites.

### Step 2 — Decommission resolver-side id stuffing

Once Step 1 lands, the id-extraction in `registerDcb`
(`CommandGeneratorResolvers_GraphQL.res:178-238`, the `idFieldName`/`argsDict`
block at lines 188-220) becomes redundant: the envelope id is derived
downstream from the same command JSON. Remove it. Keep the rest of the
resolver (SDL generation, identity extraction, payload assembly) intact.

This also removes the silent "first tagged field wins" behavior, which was
incorrect for any variant with multiple non-partition tags.

### Step 3 — Drop the now-vestigial `id` arg from AppSync DCB SDL

`registerDcb`'s SDL generation already does not inject `id: ID!` (only the
aggregate `register` does — `CommandGeneratorResolvers_GraphQL.res:140-144`),
so no SDL change is needed. Verify by inspection that no DCB mutation SDL
declares `id: ID!`. If any do, remove them.

The AppSync `invokeDcbMutation` template (`AppSync_Resolver_Functions.res:832`)
needs no change: it forwards `ctx.args` and the Lambda's `makeGenerateCommand`
now derives id from the schema.

### Step 4 — Tests

File: `reventless-core/tests/commandgenerator/CommandGeneratorCallbackTest.res`

Add cases:

1. StateChangeSlice command with `@partitionTag` annotation, args without `id`
   → envelope id equals the partition tag value.
2. StateChangeSlice command with two `@compositePartitionTag` fields, args
   without `id` → envelope id equals
   `getCompositePartitionKeyValue(extractTags, spec)`.
3. StateChangeSlice command with explicit `id` in args → envelope id is the
   supplied value (regression check).
4. Aggregate command with explicit `id` in args → unchanged behavior.

DcbTag tests already cover `getCompositePartitionKeyValue`
(`DcbTagTest.res:468-529`), so the new tests focus on the wiring.

### Step 5 — Document the contract

File: `reventless-core/src/components/CommandGenerator/CommandGenerator.res`
(or the relevant TSDoc home for `commandGenerator`).

Add a note to `payload.arguments`'s `id` field documenting that it is
optional for DCB StateChangeSlice components and is derived from the
command's partition tag when absent. Aggregates still require it.

## Scope notes

- This is purely additive on the success path and removes one ad-hoc rule
  on the failure path (`registerDcb`'s "first tagged field wins"). No
  behavior change for existing commands that already supply an id.
- Both `Reventless.DcbTag.extractTagsFromJson` and the `partitionTag`
  helpers are already public in `reventless-spec`; no new exports needed.
- The `serviceName`/`commandSchema`/`componentKind` parameters are already
  in scope at the derivation site (`CommandGenerator_Callback.res:33-39`).
