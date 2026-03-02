# Plan: Refactor `commandsHandler` to Stream-based API

## Context

The framework uses `Stream.t` (Effect streams) as its primary abstraction for lazy, composable data pipelines. Currently, `CommandTopic.commandsHandler` is the last major API boundary that still uses `array<topicItem>` and returns `promise<...>`. The callers (adapters) already convert their inputs to streams before hitting `jsonCommandsHandler`, so the stream is then unnecessarily materialized inside `CommandTopic_Callback` before being passed to the actual command handler. The goal is to push streams all the way through: handlers receive a `Stream.t` and return an `Effect.t`, eliminating the intermediate array materialization.

Secondary improvement: `groupTopicItemsById` in `Aggregate_Callback` uses a Belt.Set approach (O(n²) over the array) and is marked with a `// FIXME`. This is replaced with a single-pass `Stream.runFold` into a `Dict`.

## Type Unification

After the type change, `commandsHandler<JSON.t>` has exactly the same signature as `jsonCommandsHandler`. Types belong in the main module, not in helpers. The unification is done entirely in `CommandTopic.res`:

**`CommandTopic.res`** — two changes:

1. Move `commandsHandler<'command>` **before** `include CommandTopic_Helpers` and change it to stream-based:

```rescript
// New position: before include CommandTopic_Helpers
type commandsHandler<'command> = Stream.t<topicItem<'command>, string, unit> => Effect.t<
  array<result<string, string>>,
  string,
  unit,
>

include CommandTopic_Helpers  // line 11 — unchanged

// ... publish types ...

// After the include: re-alias jsonCommandsHandler to make the relationship explicit
type jsonCommandsHandler = commandsHandler<JSON.t>
```

The `include CommandTopic_Helpers` brings in a structural `jsonCommandsHandler` (still needed internally for `handlerEntry`). The line `type jsonCommandsHandler = commandsHandler<JSON.t>` shadows it with a proper alias, so any external code sees the unified type.

**`CommandTopic_Helpers.res`** — no changes needed. Its own `jsonCommandsHandler` structural type is identical to `commandsHandler<JSON.t>` and is used internally for `handlerEntry`. The shadowing in `CommandTopic.res` ensures external callers see the clean alias.

The `T` module type's local alias `type commandsHandler = commandsHandler<Message.command'<...>>` is unchanged.

---

## Step-by-Step Changes

### 1. `CommandTopic/CommandTopic.res`
- Move `commandsHandler<'command>` type definition to before `include CommandTopic_Helpers` (currently on line 17, after the include on line 11)
- Change the type from array-based to stream-based (see Type Unification section above)
- After the include, add `type jsonCommandsHandler = commandsHandler<JSON.t>` to shadow the structural version from helpers with a proper alias

### 2. `CommandTopic/CommandTopic_Callback.res`
Remove the `Stream.runCollect` + `Effect.flatMap` + `Effect.tryPromise` wrapping. Since `commandsHandler` now returns `Effect.t`, the decoded stream can be passed directly:

```rescript
// Before (lines 29–44)
->Stream.runCollect
->Effect.flatMap(topicItems =>
  Effect.tryPromise(
    ~catch=e => { Logger.error(...); ... },
    () => Ops.commandsHandler(topicItems),
  )
  ->Effect.map(res => { Logger.debug(...); res })
)

// After
->Ops.commandsHandler
->Effect.map(res => { Logger.debug(...); res })
```

The full pipeline in `handleJsonCommands` becomes:
```rescript
stream
->Stream.mapEffect(decode)
->Stream.flatMap(filterNone)
->Ops.commandsHandler
->Effect.map(res => { Logger.debug(...); res })
```

### 3. `Aggregate/Aggregate_Callback.res`

**Replace `groupTopicItemsById` (array-based, FIXME) with stream-based grouping:**

```rescript
let groupTopicItemsByIdStream = stream =>
  stream
  ->Stream.runFold(Dict.make(), (dict, item) => {
    let id = item.command.id->Spec.Id.toString
    let existing = dict->Dict.get(id)->Option.getOr([])
    dict->Dict.set(id, Array.concat(existing, [item]))
    dict
  })
  ->Effect.map(dict =>
    dict->Dict.entries->Array.map(((id, items)) => (id->Spec.Id.makeFromString, items))
  )
```

Single-pass fold into a `Dict` — preserves insertion order, no Belt.Set needed.

**Change `handleCommands` signature and body:**

```rescript
// Before
let handleCommands = async topicItems => {
  let results = await topicItems
  ->groupTopicItemsById
  ->Array.map(async ((id, topicItemsForId)) => { ... })
  ->Promise.all
  results->Array.flat
}

// After
let handleCommands: CommandTopic.commandsHandler<...> = stream =>
  stream
  ->groupTopicItemsByIdStream
  ->Effect.flatMap(groups =>
    Effect.promise(async () => {
      let results = await groups
      ->Array.map(async ((id, topicItemsForId)) => { ... })  // inner logic unchanged
      ->Promise.all
      results->Array.flat
    })
  )
```

The per-group processing logic (sequential `Array.reduce` over commands, `replayStream`, `eventLog.append`) is unchanged.

### 4. `StateChangeSlice/StateChangeSlice_Callback.res`

Change `T` module type (array → stream, promise → Effect) and implement with `Stream.mapEffect` + `Stream.runCollect`:

```rescript
// T module type - updated signatures
let handleCommands: (
  DcbEventLog.operations<Spec.DcbEventLogSpec.event>,
  Stream.t<CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, Spec.command>>, string, unit>,
) => Effect.t<array<result<string, string>>, string, unit>

// Implementation
let handleCommands = (dcbEventLog, stream) => {
  Logger.debug(~loc=__LOC__, "starting", "StateChangeSlice.handleCommands")
  stream
  ->Stream.mapEffect(({Reventless.CommandTopic.reference, command}) =>
    Effect.promise(async () => {
      switch await handleSingleCommand(dcbEventLog, command) {
      | Ok(_) => Ok(reference)
      | Error(_) => Error(reference)
      }
    })
  )
  ->Stream.runCollect
}
```

Each item is processed via `Stream.mapEffect` (async per item), then results are collected.

### 5. `StateChangeSlice/StateChangeSlice_Builder.res` (`makeJsonHandler`)

Remove `runCollect` + `Effect.flatMap`. Pass the decoded stream directly to `Callback.handleCommands`:

```rescript
// Before (lines 30–33)
->Stream.runCollect
->Effect.flatMap(decodedItems =>
  Effect.promise(() => Callback.handleCommands(dcbEventLogOps, decodedItems))
)

// After — build decoded stream, pass directly
let decodedStream = stream->Stream.mapEffect(decode)->Stream.flatMap(filterNones)
Callback.handleCommands(dcbEventLogOps, decodedStream)
```

### 6. `ExtensionPoint/ExtensionPoint_Callback.res`

`handleIncomingCommands` automatically picks up the new type via `CommandTopic.commandsHandler`. Internally, since `mapIncomingCommands` is array-based, the stream is collected:

```rescript
// Implementation
let handleIncomingCommands = stream =>
  stream
  ->Stream.runCollect
  ->Effect.flatMap(topicItems =>
    Effect.promise(async () => {
      let commandActions = topicItems->mapIncomingCommands(
        Mappings.mappings,
        Spec.scheduler,
        Spec.queryEngine,
        Spec.resourceNaming,
        Spec.commandTopicResources,
      )
      await commandActions->Array.map(applyCommandAction)->Promise.all
    })
  )
```

### 7. Tests (3 files)

Call sites wrap their arrays in `Stream.fromIterable` and run with `Effect.runPromise`:

**`tests/aggregate/AggregateCallbackTest.res`** (~8 call sites)
```rescript
// Before
let results = await TestHandler.handleCommands([makeTopicItem(...)])

// After
let results = await Stream.fromIterable([makeTopicItem(...)])
  ->TestHandler.handleCommands
  ->Effect.runPromise
```

**`tests/dcb/DcbStateChangeSliceTest.res`** (~12 call sites)
```rescript
// Before
let results = await TestHandler.handleCommands(testDcbEventLog, [...])

// After
let results = await TestHandler.handleCommands(
  testDcbEventLog,
  Stream.fromIterable([...]),
)->Effect.runPromise
```

**`tests/extensionpoint/ExtensionPointCallbackTest.res`** (~5 call sites)
```rescript
// Before
let results = await TestHandler.handleIncomingCommands([...])

// After
let results = await Stream.fromIterable([...])
  ->TestHandler.handleIncomingCommands
  ->Effect.runPromise
```

---

## Files Changed (summary)

| File | Change |
|------|--------|
| `reventless-core/src/components/CommandTopic/CommandTopic.res` | Move `commandsHandler` before include; change to stream-based; add `jsonCommandsHandler = commandsHandler<JSON.t>` alias |
| `reventless-core/src/components/CommandTopic/CommandTopic_Callback.res` | Remove `runCollect`+`flatMap`; pipe stream directly |
| `reventless-core/src/components/Aggregate/Aggregate_Callback.res` | Stream-based grouping + new `handleCommands` signature |
| `reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res` | Stream input + Effect return; `mapEffect`+`runCollect` |
| `reventless-core/src/components/StateChangeSlice/StateChangeSlice_Builder.res` | Remove `runCollect`; pass decoded stream directly |
| `reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res` | Stream input; internal `runCollect` before existing array logic |
| `reventless-core/tests/aggregate/AggregateCallbackTest.res` | Wrap arrays in `Stream.fromIterable`; `Effect.runPromise` |
| `reventless-core/tests/dcb/DcbStateChangeSliceTest.res` | Same |
| `reventless-core/tests/extensionpoint/ExtensionPointCallbackTest.res` | Same |

---

## Verification

```bash
cd reventless/reventless-core
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
npm test
```

All tests in `AggregateCallbackTest`, `DcbStateChangeSliceTest`, and `ExtensionPointCallbackTest` must pass.
