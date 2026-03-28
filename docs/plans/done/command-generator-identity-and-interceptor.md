# CommandGenerator: Identity Propagation and Interceptor Hook

**Status: DONE** — All changes 1–7 implemented, all 842 tests passing (2026-03-28).

## Goal

Two related improvements to the `CommandGenerator` pipeline:

1. **Identity propagation** — carry the full `Identity.t` through `CommandGenerator.payload` so it is available at every point in the dispatch path (in-memory, AWS Lambda, MCP), rather than being reduced to a userId string in `meta.user` the moment a transport builds its payload.

2. **Interceptor hook** — a module-level mutable ref in `CommandGenerator_Callback` that lets external code inspect or reject a command before `publishJsons` is called, without requiring changes to individual transport modules.

These two changes are independent but intended to land together.

---

## Affected files

| File | Package | Status |
|---|---|---|
| `src/components/CommandGenerator/CommandGenerator.res` | reventless-core | ✅ done |
| `src/components/CommandGenerator/CommandGenerator_Callback.res` | reventless-core | ✅ done |
| `src/components/Aggregate/Aggregate_Builder.res` | reventless-core | ✅ done |
| `src/components/Dcb/Dcb_Builder.res` | reventless-core | ✅ done |
| `src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res` | reventless-in-memory | ✅ done |
| `src/Platform.res` | reventless-in-memory | ✅ done |
| `src/adapter/MCP_Server.res` | reventless-in-memory | ✅ done |
| `src/adapter/MCP_ServerInstance.res` | reventless-in-memory | ✅ done (also updated) |
| `src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res` | reventless-aws | ✅ done |
| `src/adapter/Runtime/AggregateEntryPoint.mjs` | reventless-aws | ✅ done |
| `src/adapter/Mcp/MCP_Lambda.res` | reventless-aws | ✅ done |

---

## Change 1: Add `identity` to `CommandGenerator.payload`

**File:** `reventless-core/src/components/CommandGenerator/CommandGenerator.res`

Current:
```rescript
type meta = {ip: array<string>, user: string, info: string}
type payload = {
  command:   string,
  arguments: arguments,
  meta:      meta,
}
```

After:
```rescript
type meta = {ip: array<string>, user: string, info: string}
type payload = {
  command:   string,
  arguments: arguments,
  meta:      meta,
  identity:  Reventless.Identity.t,
}
```

`identity` is required (not optional) because all transport implementations already have an identity in scope when they construct the payload. The anonymous fallback (`Reventless.Identity.anonymous`) is used wherever no real identity is available.

---

## Change 2: Interceptor hook in `CommandGenerator_Callback`

**File:** `reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res`

### 2a. Add types and hook ref

```rescript
type interceptResult = Allow | Deny(string)

type commandComponentKind = Aggregate | StateChangeSlice

type commandInterceptor = (
  ~identity:      Reventless.Identity.t,
  ~componentName: string,
  ~componentKind: commandComponentKind,
  ~tag:           string,
  ~args:          JSON.t,
) => promise<interceptResult>

/** Module-level interceptor hook. None = passthrough (default). */
let commandInterceptorHook: ref<option<commandInterceptor>> = ref(None)
```

### 2b. Add `~componentKind` parameter to `makeGenerateCommand`

Current signature:
```rescript
let makeGenerateCommand = (
  ~publishJsons: CommandGenerator.publishJsons,
  ~serviceName: string,
  ~commandSchema: S.t<unknown>,
  ~stripIdFromParams: bool=true,
): CommandGenerator.commandGenerator
```

New signature:
```rescript
let makeGenerateCommand = (
  ~publishJsons:     CommandGenerator.publishJsons,
  ~serviceName:      string,
  ~commandSchema:    S.t<unknown>,
  ~componentKind:    commandComponentKind,
  ~stripIdFromParams: bool=true,
): CommandGenerator.commandGenerator
```

### 2c. Call the hook before `publishJsons`

In the `Effect.flatMap` that currently calls `publishJsons`, prepend the interceptor call:

```rescript
->Effect.flatMap(((meta, commandJson, id)) => {
  let interceptEffect = switch commandInterceptorHook.contents {
  | Some(interceptor) =>
    Effect.promise(() =>
      interceptor(
        ~identity=payload.identity,
        ~componentName=serviceName,
        ~componentKind,
        ~tag=payload.command,
        ~args=payload.arguments->Obj.magic,
      )
    )
  | None => Effect.succeed(Allow)
  }
  interceptEffect->Effect.flatMap(interceptResult =>
    switch interceptResult {
    | Allow =>
      Effect.promise(() => publishJsons([{id, meta, commandJson}]))
      ->Effect.map(_ => meta.msgId)
    | Deny(msg) =>
      Effect.fail(msg)
    }
  )
})
```

### 2d. Update `Make` functor

The `Make` functor at the bottom of the file calls `makeGenerateCommand`. Add `~componentKind=Aggregate` (the functor is only used for aggregates):

```rescript
module Make = (Spec: Spec, AggregateSpec: Reventless.Aggregate.Spec): T => {
  let generateCommand = makeGenerateCommand(
    ~publishJsons=Spec.publishJsons,
    ~serviceName=AggregateSpec.name,
    ~commandSchema=AggregateSpec.commandSchema->S.castToUnknown,
    ~componentKind=Aggregate,
  )
}
```

---

## Change 3: Populate `payload.identity` in GraphQL resolvers

**File:** `reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res`

Both `register` and `registerDcb` construct a `CommandGenerator.payload` literal. Both already call `extractIdentity(ctx)` immediately beforehand — add `identity` to the payload record.

**In `register`'s resolver closure** (currently around line 88):
```rescript
let payload: CommandGenerator.payload = {
  command:   commandName,
  arguments: args->Obj.magic,
  meta:      {ip: [], user: identity.userId, info: `Mutation.${field}`},
  identity,           // add this line
}
```

**In `registerDcb`'s resolver closure** (currently around line 153):
```rescript
let payload: CommandGenerator.payload = {
  command:   tag,
  arguments: argsDict->Obj.magic,
  meta:      {ip: [], user: identity.userId, info: `Mutation.${fieldName}`},
  identity,           // add this line
}
```

---

## Change 4: Populate `payload.identity` in AppSync VTL templates

**File:** `reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res`

Both `invokeCommandGenerator` (Aggregate mutations) and `invokeDcbMutation` (DCB StateChangeSlice mutations) build the Lambda payload via VTL. Add an `identity` block using AppSync's Cognito context.

AppSync with a Cognito User Pool authorizer exposes:
- `$context.identity.sub` — Cognito UUID (stable user identifier)
- `$context.identity.username` — Cognito username
- `$context.identity.claims` — all JWT claims, including `cognito:groups`

**Updated template (applies to both `invokeCommandGenerator` and `invokeDcbMutation`):**

```vtl
{
  "version": "2017-02-28",
  "operation": "Invoke",
  "payload": {
    "command":   "${command}",
    "arguments": $utils.toJson($context.arguments),
    "meta": {
      "ip":   $util.toJson($context.identity.sourceIp),
      "user": $util.toJson($context.identity.username),
      "info": $util.toJson("$parentTypeName.$fieldName")
    },
    "identity": {
      "userId":   $util.toJson($context.identity.sub),
      "username": $util.toJson($context.identity.username),
      "groups":   $util.defaultIfNull($context.identity.claims.get("cognito:groups"), []),
      "claims":   $util.toJson($context.identity.claims),
      "provider": "Cognito"
    }
  }
}
```

If no Cognito authorizer is configured, `$context.identity` may not have these fields. The Lambda entry point (`AggregateEntryPoint`) should apply a fallback when `payload.identity` is absent, reconstructing a minimal identity from `meta.user`:

```rescript
// In AggregateEntryPoint, before passing event to generateCommand:
let identity =
  switch payload.identity->Obj.magic->Nullable.toOption {
  | Some(id) => id
  | None => {
      Reventless.Identity.userId:   payload.meta.user,
      username: payload.meta.user,
      groups:   [],
      provider: Custom("aws"),
    }
  }
let payloadWithIdentity = {...payload, identity}
```

---

## Change 5: Pass `~componentKind` at all `makeGenerateCommand` call sites

`makeGenerateCommand` gains a required `~componentKind` parameter (Change 2b). All call sites must be updated.

**`reventless-core/src/components/Aggregate/Aggregate_Builder.res` (line ~116):**
```rescript
let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons,
  ~serviceName=Spec.name,
  ~commandSchema=Spec.commandSchema->S.castToUnknown,
  ~componentKind=Aggregate,    // add
)
```

**`reventless-core/src/components/Dcb/Dcb_Builder.res` (line ~171 — in-memory StateChangeSlice binding):**
```rescript
let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons=ops.publishJsons,
  ~serviceName=S.Spec.name,
  ~commandSchema=S.Spec.commandSchema->Obj.magic,
  ~componentKind=StateChangeSlice,    // add
  ~stripIdFromParams=false,
)
```

**`reventless-core/src/components/Dcb/Dcb_Builder.res` (line ~296 — DCB shared AppSync generateCommand):**
```rescript
CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons=ops.publishJsons,
  ~serviceName=name,
  ~commandSchema=S.json->S.castToUnknown,
  ~componentKind=StateChangeSlice,    // add
  ~stripIdFromParams=false,
)
```

**`reventless-aws/builder/layer/.../AggregateEntryPoint.res` — `buildCommandGeneratorHandler` (line ~196):**
```rescript
let generateCommand = makeGenerateCommand(
  publishJsons,
  specModule->getName,
  behaviorModule->getResolverConfig->getCommandSchema,
  Some(true),       // stripIdFromParams (existing positional arg)
)
// becomes:
let generateCommand = makeGenerateCommand(
  publishJsons,
  specModule->getName,
  behaviorModule->getResolverConfig->getCommandSchema,
  "Aggregate",      // componentKind (new positional arg — insert before stripIdFromParams)
  Some(true),
)
```

Note: `AggregateEntryPoint` uses `@module` externals with positional arguments. The `makeGenerateCommand` external binding must be updated to include `componentKind` at the correct position.

---

## Change 6: In-memory MCP — surface real identity to `commandHandler`

**Files:** `reventless-in-memory/src/adapter/MCP_Server.res` and `reventless-in-memory/src/Platform.res`

### Problem

The MCP `commandHandler` is currently typed as `(string, JSON.t) => promise<string>` and the tool call implementation invokes the GraphQL mutation resolver with a null context:

```rescript
// Platform.res — current
let result = await resolver(JSON.Encode.null, args, JSON.Encode.null)
//                          ^^^^ null ctx → identity = anonymous
```

`extractIdentity` falls back to `Identity.anonymous` for every MCP tool call.

### Fix: extend `commandHandler` signature

**`MCP_Server.res`** — update the `registerToolsFromEntries` signature:

```rescript
// current
~commandHandler: (string, JSON.t) => promise<string>

// updated
~commandHandler: (string, JSON.t, Reventless.Identity.t) => promise<string>
```

In the tool's handler closure, pass identity to `commandHandler`:

```rescript
let handler: toolHandler = async (args, identity) => {
  try {
    let result = await commandHandler(def.name, args, identity)
    McpSdk_Helpers.toolResult(result)
  } catch {
  | exn => ...
  }
}
```

The MCP server extracts identity before calling the tool handler. For MCP 1.0 (OAuth 2.0), the Bearer token in the Authorization header is validated against the Cognito User Pool and decoded to produce an `Identity.t`. The `onCallTool` handler receives the request object and can read the header.

**`Platform.res`** — update the `commandHandler` closure to accept and use `identity`:

```rescript
~commandHandler=async (toolName, args, identity) => {
  // Build a synthetic GraphQL context that extractIdentity can read,
  // or — simpler — build the payload directly using identity:
  switch CommandGeneratorResolvers_GraphQL.handlerRefs->Dict.get(toolName) {
  | Some(handlerRef) =>
    switch handlerRef.contents {
    | Some(generateCommand) =>
      // Build payload directly, bypassing the resolver's ctx extraction
      let payload: CommandGenerator.payload = {
        command:   toolName,
        arguments: args->Obj.magic,
        meta:      {ip: [], user: identity.userId, info: `mcp/tools/${toolName}`},
        identity,
      }
      let result = await generateCommand(payload)->Effect.runPromise
      result
    | None => `error: no handler for ${toolName}`
    }
  | None => `error: no handler for ${toolName}`
  }
}
```

This bypasses the synthetic resolver call entirely and builds the payload directly using the real identity — which is cleaner and removes the null-context workaround.

---

## Change 7: AWS MCP — route through `makeGenerateCommand`

**File:** `reventless-aws/src/adapter/Mcp/MCP_Lambda.res`

### Problem

AWS MCP tool handlers currently dispatch by publishing directly to SQS, bypassing `makeGenerateCommand`:

```rescript
// current — direct SQS publish, interceptor hook never called
SQS.sendMessage(~queueUrl=tool.commandTopicArn, ~body=commandJson)
```

### Fix

Replace with a call through `makeGenerateCommand` so the interceptor hook fires. The tool's `commandTopicArn` already tells us which SQS queue to target.

The `mcpConfig` already contains `commandTopicArn` per tool. The `commandSchema` is not available at runtime in `MCP_Lambda` — use `S.json->S.castToUnknown` (permissive, same as the DCB AppSync path in `Dcb_Builder`) since AppSync and MCP both validate input at the API layer before the Lambda receives it.

The MCP server receives the OAuth Bearer token from the Authorization header. Validate it against Cognito to obtain `Identity.t` before dispatching.

```rescript
// updated tool handler — called per MCP tools/call request
let dispatchTool = async (tool: mcpToolEntry, args: JSON.t, identity: Reventless.Identity.t) => {
  let queueRef = makeQueueRef(tool.commandTopicArn)
  let publishJsons = sqsPublishJsons(queueRef, "SQS_FIFO")
  let generateCommand = makeGenerateCommand(
    publishJsons,
    tool.name,
    S.json->S.castToUnknown,  // permissive schema — MCP validates at API layer
    "Aggregate",              // componentKind (most MCP tools are aggregate commands;
                              // DCB tools use "StateChangeSlice" — derive from mcpConfig)
    Some(false),              // stripIdFromParams=false (id is embedded in args)
  )
  let payload: CommandGenerator.payload = {
    command:   tool.name,
    arguments: args->Obj.magic,
    meta:      {ip: [], user: identity.userId, info: `mcp/tools/${tool.name}`},
    identity,
  }
  await runEffect(None, generateCommand(payload))
}
```

`mcpConfig` should carry `componentKind` per tool (either `"Aggregate"` or `"StateChangeSlice"`) so that `dispatchTool` can pass the correct value. Update `mcpToolEntry` and `generateConfig` accordingly:

```rescript
type mcpToolEntry = {
  name:            string,
  description:     string,
  inputSchema:     JSON.t,
  commandTopicArn: string,
  componentKind:   string,   // "Aggregate" | "StateChangeSlice"
}
```

`generateConfig` receives `mutationEntries` which includes enough schema information to determine kind — aggregates come from `Union({anyOf})` schemas, DCB slices from `Object(_)` schemas (see `MCP_SchemaGenerator.generateTools`).

---

## Implementation order

```
Changes 1–2 must land first — they define the types and hook used by all other changes.
  │
  ├─ Change 3 (GraphQL resolvers)       depends on 1   ✅
  ├─ Change 4 (AppSync VTL)             depends on 1   ✅
  ├─ Change 5 (call sites)              depends on 2   ✅
  │   (Changes 3, 4, 5 can be parallel)
  │
  ├─ Change 6 (in-memory MCP)           depends on 1–2 ✅
  ├─ Change 7 (AWS MCP)                 depends on 1–2 ✅
```

Changes 1–5 form the complete path for GraphQL and AppSync. Changes 6–7 add MCP coverage.

## Implementation notes (actual)

- `commandComponentKind` variant (`Aggregate | StateChangeSlice`) compiles to strings in ReScript 12
  (`"Aggregate"`, `"StateChangeSlice"`), so `AggregateEntryPoint.mjs` passes the string literal.
- `AggregateEntryPoint.mjs` is hand-written JavaScript (not compiled from `.res`); updated directly.
  The positional arg order for `makeGenerateCommand` is `(publishJsons, serviceName, commandSchema, componentKind, stripIdFromParams)`.
- Identity fallback in `AggregateEntryPoint.mjs`: if payload arrives without `identity` (non-Cognito
  authorizer), reconstructs from `meta.user` with `provider: {TAG: "Custom", _0: "aws"}`.
- Deny from interceptor uses `JsError.throwWithMessage` (not `Effect.fail`) to avoid changing the
  typed error channel of `commandGenerator = payload => Effect.t<string, unit, unit>`.
- `MCP_ServerInstance.res` (split-mode admin MCP) was also updated alongside `MCP_Server.res`.
- Change 6 in Platform.res bypasses the null-context GraphQL resolver entirely; builds
  `CommandGenerator.payload` directly from `handlerRefs` using the real identity.
- Change 7 in `MCP_Lambda.res`: added `componentKind` to `mcpToolEntry`; `generateConfig`
  derives kind by pattern-matching `commandSchema` (`Union(_)` = Aggregate, else StateChangeSlice).
  Added `dispatchTool` using `makeGenerateCommand` + `sqsPublishJsons` external bindings.
  JWT identity extraction decodes the base64url payload without re-verification (trusting the
  upstream Lambda authorizer/API Gateway Cognito authorizer already validated the token).
  `Option.orElse` in RescriptCore takes `option<'a>` (not a thunk) — pass the value directly.

---

## Tests to add / update

- `CommandGenerator_Callback` unit tests: interceptor hook fires before `publishJsons`; `Deny` prevents `publishJsons` from being called; `Allow` proceeds normally; `None` hook = passthrough
- `CommandGeneratorResolvers_GraphQL` tests: `payload.identity` is populated from the GraphQL context's `X-Identity` header; anonymous fallback when header absent
- MCP integration tests (in-memory): tool call with a Bearer token populates real identity; anonymous fallback when no token present
