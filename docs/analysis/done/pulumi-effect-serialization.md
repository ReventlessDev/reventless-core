# Pulumi CallbackFunction + Effect Serialization Issue

## Problem

When running `pulumi preview` (or `pulumi up`) for the online-shop-hybrid platform stack, Pulumi fails to serialize certain Lambda handler closures:

```
error: Error serializing function 'callback': Util_DeadLetterQueue.res.mjs(28,17)
  captured variable 'Effect' which indirectly referenced ...
  function is not a bound function
```

Pulumi's `CallbackFunction` serializes the handler closure (and all captured variables) into deployable Lambda code. The `effect` library's runtime objects contain native functions that cannot be serialized.

## Root Cause

Three files capture `Effect` directly in closures that Pulumi tries to serialize:

### 1. `Util_DeadLetterQueue.res` (lines 25-28) — **blocks all deployments**

```rescript
let callback: Lambda.eventHandlerNoResult<'a> = (evt, _ctx) =>
  Effect.logError(
    "DEAD LETTER ITEM: " ++ evt->JSON.stringifyAny->Option.getOr("<unknown>"),
  )->Effect.runPromise
```

The DLQ callback is created at module init and passed to `Lambda.CallbackFunction.make`. `Effect` is captured in the closure. Since both CommandTopic (SQS) and EventCollector (SQS) use the DLQ, this blocks all infrastructure creation.

### 2. `ClonerRunner_Fargate_Runtime.res` (lines 3-42) — **blocks cloner**

```rescript
let clone = (~taskDefinition, ~cluster, ~fullQualifiedStackName, ~subnets, payload, _) => {
  Effect.logInfo("clone: requested by user " ++ ...)
  ->Effect.flatMap(_ => Effect.promise(() => ...))
  ->Effect.runPromise
```

Only impacts deployments with `cloner: true`.

### 3. `CounterHandler_DynamoDbStream_Runtime.res` (lines 63-119) — **blocks counter**

```rescript
let makeHandler = (...) => async (event, _ctx) => {
  await Effect.tryPromise(...)
    ->Effect.flatMap(...)
    ->Effect.runPromise
```

Only impacts plugins that use the Counter component.

## Why Other Handlers Work

Most handlers in the codebase use a safe pattern where `Effect` is called inside an `async` function body, not captured in the outer closure:

```rescript
// SAFE: Effect called at runtime inside async body
let handler = async (event, _ctx) => {
  let result = await someOperation()
  let _ = Effect.logInfo("done")->Effect.runSync  // runtime-only
}

// BROKEN: Effect captured in closure (serialized by Pulumi)
let handler = (event, _ctx) =>
  Effect.logError("msg")->Effect.runPromise  // Effect captured at definition
```

The critical difference: in the safe pattern, `Effect` is referenced inside the async function body which Pulumi serializes as source text. In the broken pattern, `Effect` is a captured variable in the closure scope that Pulumi tries to serialize as a runtime object.

## Fix Options

### Option A: Convert broken handlers to async/await pattern (minimal change)

Replace `Effect.runPromise` closures with `async`/`await` + `console.log`:

```rescript
// Util_DeadLetterQueue.res — before
let callback = (evt, _ctx) =>
  Effect.logError("DEAD LETTER ITEM: " ++ ...)->Effect.runPromise

// Util_DeadLetterQueue.res — after
let callback = async (evt, _ctx) => {
  Console.error("DEAD LETTER ITEM: " ++ evt->JSON.stringifyAny->Option.getOr("<unknown>"))
}
```

**Pros:** Minimal change, fixes the immediate issue.
**Cons:** Loses structured Effect logging in these three handlers.

### Option B: Move to Pulumi code archives instead of CallbackFunction

Replace `Lambda.CallbackFunction.make` with `Lambda.Function.make` using a pre-bundled ZIP archive. The handler code runs from the archive at runtime, avoiding serialization entirely.

**Pros:** Eliminates all serialization constraints; enables any runtime library.
**Cons:** Requires a build step to bundle Lambda code into ZIPs; significant architecture change to `RuntimeEnvironment_Lambda`; all handler creation flows need reworking.

### Option C: Use Pulumi's `allowSecrets`/custom serialization

Pulumi's JS SDK supports custom serialization callbacks. We could register a custom serializer for `Effect` that produces a `require("effect")` call at runtime instead of serializing the object.

**Pros:** Transparent fix; no handler changes needed.
**Cons:** Relies on undocumented Pulumi internals; fragile across Pulumi versions.

### Option D: Lazy Effect import at runtime

Replace direct `Effect` module reference with a dynamic `import()` inside the handler:

```rescript
let callback = async (evt, _ctx) => {
  let effect = await import("effect")
  // use effect.Effect.logError(...)
}
```

**Pros:** Effect is never captured in the closure.
**Cons:** Requires raw JS interop for dynamic import; changes the API surface of the handlers.

## Recommendation

**Option A** for the immediate fix — the three broken handlers use Effect only for logging, which can be replaced with `Console.error`/`Console.log` without functional loss. This unblocks deployment immediately.

**Option B** as a future improvement — code archives are the standard Lambda deployment pattern for production workloads. They avoid serialization issues entirely and enable better dependency management (tree-shaking, smaller bundles). This should be planned as a separate workstream.

## Affected Components

| Component | File | Impact |
|-----------|------|--------|
| Dead Letter Queue | `reventless-aws/src/util/Util_DeadLetterQueue.res` | All SQS-based infrastructure (CommandTopic, EventCollector) |
| Cloner | `reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate_Runtime.res` | Only when `cloner: true` |
| Counter | `reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res` | Only when Counter component is used |
