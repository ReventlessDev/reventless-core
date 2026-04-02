# Plan: Multi-Command Returns in InboundTranslationSlice

Extend `InboundTranslationSlice.Spec.translate` to support returning multiple commands from a single external input. This enables batch ingestion patterns where one external event produces commands targeting multiple DCB entities.

## Motivation

The current `translate` contract enforces a strict 1:1 mapping:

```rescript
let translate: externalInput => result<(string, command), string>
```

One external input produces exactly one `(targetId, command)` pair. This works for simple translations (e.g. `ImportProduct` → `AddProduct`) but breaks down for batch patterns where a single external event describes a tree of entities.

**Concrete use cases:**
- Importing a CSV/JSON file that creates multiple aggregates
- Webhook payloads that carry nested entity trees (e.g. a deployment batch containing platforms, plugins, components, and resources)
- Message queue consumers that receive batch messages
- Sync operations that reconcile external state into multiple internal entities

Today these fan-out patterns require imperative hook code outside the DCB framework — the `translate` function cannot express them.

## Current Contract

### Spec (`reventless-spec`)

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string
  @schema type externalInput
  @schema type command
  let translate: externalInput => result<(string, command), string>
}
```

### Callback (`reventless-core`)

In `InboundTranslationSlice_Callback.res`, `receive` calls `translate` and publishes one command:

```rescript
switch Spec.translate(input) {
| Ok((targetId, cmd)) =>
  let commandJson = cmd->S.reverseConvertToJsonOrThrow(Spec.commandSchema)
  let msg: Reventless.Message.commandJson = {
    id: targetId,
    meta: makeMeta(),
    commandJson,
  }
  await publishJsons([msg])
  Ok(targetId)
| Error(msg) => Error(msg)
}
```

The `publishJsons` function already accepts `array<Message.commandJson>` — it is called with a single-element array `[msg]` by convention, not by necessity.

### Resolvers

- **In-memory (GraphQL):** Returns `result<string, string>` — one targetId or error
- **AWS (AppSync):** Returns targetId string via resolver response template

### Audit log

One audit row per `receive` call, keyed by request ID. Stores `targetId` (singular) on success.

## Proposed Change

### New Spec contract

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string
  @schema type externalInput
  @schema type command
  let translate: externalInput => result<array<(string, command)>, string>
}
```

`translate` returns an array of `(targetId, command)` pairs. For single-command translations, return a one-element array. For batch translations, return N elements.

### Updated Callback

```rescript
switch Spec.translate(input) {
| Ok(pairs) if pairs->Array.length === 0 =>
  // Empty array — nothing to publish (valid for idempotent no-op translations)
  Ok([])
| Ok(pairs) =>
  let msgs = pairs->Array.map(((targetId, cmd)) => {
    let commandJson = cmd->S.reverseConvertToJsonOrThrow(Spec.commandSchema)
    Reventless.Message.commandJson {
      id: targetId,
      meta: makeMeta(),
      commandJson,
    }
  })
  await publishJsons(msgs)
  let targetIds = pairs->Array.map(((targetId, _)) => targetId)
  Ok(targetIds)
| Error(msg) => Error(msg)
}
```

Key changes:
- Maps over all pairs, serialises each command
- Publishes all commands in a single `publishJsons(msgs)` call (one batch, not N individual calls)
- Returns `array<string>` (all targetIds) instead of `string`

### Updated operations type

```rescript
// reventless-infra
type operations = {
  receive: JSON.t => promise<result<array<string>, string>>,
}
```

Returns `array<string>` — all targetIds from the batch.

### Updated resolvers

**In-memory (GraphQL):**

```rescript
let resolver: GraphQL_Server.resolverFn = async (_root, args, _ctx) => {
  let inputJson: JSON.t = args->Obj.magic
  switch receiveRegistry->Dict.get(fieldName) {
  | Some(receive) =>
    switch await receive(inputJson) {
    | Ok(targetIds) => targetIds->JSON.Encode.array(JSON.Encode.string)
    | Error(msg) => msg->JSON.Encode.string
    }
  | None => ...
  }
}
```

The GraphQL return type changes from `String` to `[String]`. Single-command translations return `["someId"]`, batch translations return `["id1", "id2", ...]`.

**AWS (AppSync):**

The response template already handles JSON — returning an array instead of a string requires updating the AppSync resolver response mapping template and the SDL mutation return type.

### Updated audit log

```rescript
@schema
type auditRow = {
  input: JSON.t,
  status: auditStatus,
  targetIds?: array<string>,    // was: targetId?: string
  commandCount?: int,           // new: number of commands published
  error?: string,
  receivedAt: string,
}
```

One audit row per `receive` call. For a batch of 50 commands, one audit row with `commandCount: 50` and `targetIds: [...]`.

## Backward Compatibility

### Existing translate functions

Every existing `translate` function returns `Ok((targetId, cmd))`. These must be updated to return `Ok([(targetId, cmd)])` — wrapping the tuple in a one-element array.

This is a breaking change to the `Spec` module type. All consumers must update.

### Migration

The change is mechanical — wrap every `Ok((id, cmd))` in `Ok([(id, cmd)])`:

```rescript
// Before
let translate = (input: externalInput) =>
  Ok((input.sku, AddProduct({productId: input.sku, ...})))

// After
let translate = (input: externalInput) =>
  Ok([(input.sku, AddProduct({productId: input.sku, ...}))])
```

Search pattern: `grep -r "Ok((" */InboundTranslation*` in both core examples and business repo.

## Impact

### Core changes (`reventless-core`)

| File | Change |
|------|--------|
| `reventless-spec/src/components/InboundTranslationSlice.res` | `translate` return type: `result<array<(string, command)>, string>` |
| `reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res` | Map over pairs, batch publish, return `array<string>` |
| `reventless-infra/src/components/InboundTranslationSlice.res` | `operations.receive` returns `result<array<string>, string>` |
| `reventless-in-memory/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res` | Return JSON array of targetIds |
| `reventless-aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res` | Update response template for array return |
| `rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` | Update `invokeInboundTranslation` response mapping |

### Core examples

| File | Change |
|------|--------|
| `examples/online-shop-hybrid/catalog/src/Product/InboundTranslationSlice/ImportProduct.res` | Wrap return in array |

### Core tests

| File | Change |
|------|--------|
| `reventless-in-memory/tests/components/inboundtranslationslice/InboundTranslationSliceCallbackTest.res` | Update assertions for array returns, add multi-command test |

### Downstream consumer changes

Any application using `InboundTranslationSlice` must update its `translate` functions to return arrays (mechanical wrapping — see Migration section above).

## Implementation Steps

1. **Update Spec type** — change `translate` return type in `InboundTranslationSlice.res`
2. **Update Callback** — map over pairs, batch publish, return targetIds array
3. **Update operations type** — `receive` returns `result<array<string>, string>`
4. **Update in-memory resolver** — return JSON array
5. **Update AWS resolver** — update response template
6. **Update audit log schema** — `targetIds` array, `commandCount`
7. **Migrate core examples** — wrap returns in one-element arrays
8. **Update core tests** — fix assertions, add multi-command test case
