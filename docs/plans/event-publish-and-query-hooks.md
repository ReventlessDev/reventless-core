# Event Publish and Query Hooks — Core Integration Plan

> This plan is for `reventless-core`. Move to `reventless-core/docs/plans/event-publish-and-query-hooks.md` before implementation.

## Problem

The core defines runtime callback hooks (`commandInterceptorHook`, `queryInterceptorHook`) that allow external extensions to intercept commands and queries. However, two categories of hooks are defined but never invoked:

- **Event publish hooks (BeforePublish / AfterPublish):** No callback mechanism exists in core. Extensions cannot observe or transform events during publication.
- **Query interceptor on AWS:** The `queryInterceptorHook` is called by `QueryDbResolvers_GraphQL` (in-memory adapter), but has no equivalent call site in the AWS adapter (AppSync resolvers go directly to DynamoDB via VTL).

## Design Principles

1. **Core stays agnostic.** Core defines optional callback refs with generic signatures. It never imports or references extension types.
2. **Platform-independent.** Hook call sites live in `reventless-core` Operations modules (shared by all platforms), not in platform adapters.
3. **Follow established pattern.** Use the same `ref<option<callback>>` pattern as `CommandGenerator_Callback.commandInterceptorHook`.
4. **All event publish paths covered.** Aggregates, DCBs/StateChangeSlices, and ExtensionPoints all publish events through different Operations modules — all must call the hooks.

## Audit: Current State

| Integration Point | Core Location | Called? | Platform |
|---|---|---|---|
| Command interceptor | `CommandGenerator_Callback.res:80` | Yes | All (core) |
| Query interceptor | `QueryDbResolvers_GraphQL.res:45` | Yes | In-memory only (adapter) |
| BeforePublish hooks | — | No | — |
| AfterPublish hooks | — | No | — |

### Event Publish Paths (where hooks must fire)

| Component | Publishes events via | Module |
|---|---|---|
| **Aggregate** | `EventLog_Operations.append` → storage + `publishToEventTopic` | `reventless-core` |
| **DCB / StateChangeSlice** | `DcbEventLog_Operations.append` → storage + `publishToEventTopic` | `reventless-core` |
| **ExtensionPoint** | `ExtensionPoint_Operations.applyEventAction` → `publishToEventTopic` | `reventless-core` |

Other components (AutomationSlice, OutboundTranslation, InboundTranslation, EventMapper, Extension, Heartbeat) publish **commands** to the CommandTopic — not events. These are already covered by the command interceptor and are not relevant for event hooks.

## Plan

### Step 1: Create `EventPublish_Callback.res` in core ✅

New file: `src/components/EventLog/EventPublish_Callback.res`

Define the callback types and refs following the `CommandGenerator_Callback` pattern:

```rescript
type publishedEvent = {
  componentName: string,
  entityId: string,
  eventCount: int,
  eventsJson: array<JSON.t>,
  meta: Message.meta,
}

type beforePublishHook = publishedEvent => promise<publishedEvent>
type afterPublishHook = publishedEvent => promise<unit>

let beforePublishHook: ref<option<beforePublishHook>> = ref(None)
let afterPublishHook: ref<option<afterPublishHook>> = ref(None)
```

**Key decisions:**
- The `publishedEvent` type is defined in core with core types only. External extensions map their own types to this.
- Uses `componentName` (not `aggregateName`) because DCBs and ExtensionPoints also publish events.
- `beforePublishHook` returns a (possibly transformed) event — the caller uses the returned `eventsJson` for publication.
- `afterPublishHook` is fire-and-forget — errors are caught and logged, never propagated to the caller.

### Step 2: Wire hooks into `EventLog_Operations.append` ✅

File: `src/components/EventLog/EventLog_Operations.res`

In the `append` function (line 76-108), the current flow is:
```
storage.append(sequenceNr, idStr, eventsJson)  →  publishToEventTopic(id, events')
```

Change to:
```
storage.append(sequenceNr, idStr, eventsJson)
  →  run beforePublishHook (may transform eventsJson for publication)
  →  publishToEventTopic(id, transformedEvents')
  →  run afterPublishHook (observe only)
```

The component name comes from `Spec.name` and entity ID from the `id` parameter.

Error handling:
- If `beforePublishHook` throws: log the error, publish the original (untransformed) events.
- If `afterPublishHook` throws: log the error, return Ok() — the publish already succeeded.

### Step 3: Wire hooks into `DcbEventLog_Operations.append` ✅

File: `src/components/DcbEventLog/DcbEventLog_Operations.res`

Same pattern as Step 2. The DCB append publishes events via its own `publishToEventTopic`. Insert `beforePublishHook` before and `afterPublishHook` after the topic publication.

The component name comes from the DCB spec name.

### Step 4: Wire hooks into `ExtensionPoint_Operations.applyEventAction` ✅

File: `src/components/ExtensionPoint/ExtensionPoint_Operations.res`

ExtensionPoints publish events directly to EventTopic (not through EventLog storage). Insert both hooks around the `publishToEventTopic` call.

### Step 5: Verify hooks are callable by extensions ✅

The hooks follow the same pattern as `CommandGenerator_Callback.commandInterceptorHook`: a `ref<option<callback>>` that external code sets at init time. No core changes are needed beyond defining the refs — extensions set them and core calls them.

Verify that the `EventPublish_Callback` module is exported from `ReventlessCore` so external packages can access `beforePublishHook` and `afterPublishHook`.

### Step 6: Wire query interceptor into AWS AppSync resolvers ✅

The `queryInterceptorHook` is invoked in the in-memory adapter (`QueryDbResolvers_GraphQL.res:45-55`) but **not** on AWS. On AWS, QueryDb queries currently use **unit resolvers** that go directly from AppSync to DynamoDB via VTL — no Lambda, no hook call.

#### Current AWS query flow
```
AppSync GraphQL query
  → VTL request template (transforms args → DynamoDB params)
  → DynamoDB (GetItem / Query / Scan)
  → VTL response template (transforms result → GraphQL response)
```

No Lambda is involved, so there is no place to call `queryInterceptorHook`.

#### Existing precedent: pipeline resolver with auth function

`QueryDbResolvers_AppSync.res` already uses pipeline resolvers for index queries with `authorization` config (lines 116-153):

```
AppSync GraphQL query
  → Pipeline function 1: Auth (DynamoDB lookup + VTL group check)
  → Pipeline function 2: Query (DynamoDB query)
```

This pattern proves that pipeline resolvers with an authorization stage work on AWS.

#### Proposed AWS query flow

Convert unit resolvers to **pipeline resolvers** with a Lambda authorization function:

```
AppSync GraphQL query
  → Pipeline function 1: Lambda (extracts identity, calls queryInterceptorHook)
    → Allow: passes through to next function
    → Deny: returns error / null
  → Pipeline function 2: DynamoDB query (existing VTL template, unchanged)
```

#### Implementation

**Step 6a: Create a query interceptor Lambda handler**

New file: `reventless-aws/src/adapter/QueryDb/QueryInterceptor_Lambda.res`

A lightweight Lambda function that:
1. Receives identity from the AppSync VTL payload (same extraction as `CommandGeneratorResolvers_AppSync` lines 141-152)
2. Calls `QueryDb_Callback.queryInterceptorHook` with the identity, read model name, and args
3. Returns `Allow` or raises `$util.unauthorized()` equivalent

```rescript
type payload = {
  readModelName: string,
  args: JSON.t,
  identity: Reventless.Identity.t,
}

let handler = async (event: payload, _context) => {
  switch QueryDb_Callback.queryInterceptorHook.contents {
  | None => true
  | Some(interceptor) =>
    switch await interceptor(
      ~identity=event.identity,
      ~readModelName=event.readModelName,
      ~args=event.args,
    ) {
    | Allow => true
    | Deny(msg) => JsError.throwWithMessage(msg)
    }
  }
}
```

**Step 6b: Create VTL template for the interceptor invocation**

The request template extracts identity from `$context.identity` and passes it to the Lambda:

```vtl
{
  "version": "2017-02-28",
  "operation": "Invoke",
  "payload": {
    "readModelName": "${readModelName}",
    "arguments": $utils.toJson($context.arguments),
    "identity": {
      "userId": $util.toJson($context.identity.sub),
      "username": $util.toJson($context.identity.username),
      "groups": $util.defaultIfNull($context.identity.claims.get("cognito:groups"), []),
      "claims": $util.toJson($context.identity.claims),
      "provider": "Cognito"
    }
  }
}
```

The response template checks for errors and passes through:
```vtl
#if($ctx.error)
  $util.error($ctx.error.message, $ctx.error.type)
#end
$util.toJson($ctx.result)
```

**Step 6c: Modify `QueryDbResolvers_AppSync.res` to use pipeline resolvers**

Convert the existing unit resolvers (`resolverByIdSingle`, `resolverAll`, etc.) to pipeline resolvers:

1. Create a shared Lambda DataSource for the interceptor (one per plugin, reused across all QueryDb resolvers)
2. Create an AppSync Function for the interceptor Lambda
3. Create an AppSync Function for each DynamoDB query (wrapping the existing VTL templates)
4. Replace `Resolver.makeUnitResolver` calls with `Resolver.makePipelineResolver` that chains: interceptor function → query function

This mirrors the existing pattern at lines 128-153 for index authorization.

**Step 6d: Wire the Lambda into the platform entry point**

The interceptor Lambda must have the hooks initialized (so `queryInterceptorHook` is set). Two options:

- **Option A (recommended):** Bundle the query interceptor into the existing aggregate handler Lambda. Extensions are already initialized there via the entry point. Add a route that handles query interception payloads alongside command payloads.
- **Option B:** Create a dedicated interceptor Lambda. Simpler isolation but adds a cold-start cost per query. Requires its own hook initialization.

**Step 6e: Conditional pipeline — skip interceptor when not configured**

If no `queryInterceptorHook` is set, the interceptor Lambda returns `Allow` immediately — one Lambda invocation overhead per query for no benefit. Avoid this by making pipeline resolver creation conditional:

- Add a deploy-time flag to `platformHooks` indicating whether query interception is enabled (e.g. `queryInterceptionEnabled?: bool`).
- When the flag is absent or false, `QueryDbResolvers_AppSync.res` creates the existing unit resolvers (current behavior, zero overhead).
- When the flag is true, create pipeline resolvers with the interceptor function as described in Step 6c.

This ensures platforms without query interception pay no performance cost.

## File Changes Summary

### Core (`reventless-core`)

| File | Change |
|---|---|
| `src/components/EventLog/EventPublish_Callback.res` | **New** — callback types and refs |
| `src/components/EventLog/EventLog_Operations.res` | Call `beforePublishHook` before and `afterPublishHook` after `publishToEventTopic` |
| `src/components/DcbEventLog/DcbEventLog_Operations.res` | Same hook calls around `publishToEventTopic` |
| `src/components/ExtensionPoint/ExtensionPoint_Operations.res` | Same hook calls around `publishToEventTopic` |

### AWS adapter (`reventless-aws`)

| File | Change |
|---|---|
| `src/adapter/QueryDb/QueryInterceptor_Lambda.res` | **New** — Lambda handler that calls `queryInterceptorHook` |
| `src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | Convert unit resolvers to pipeline resolvers with interceptor function |

## Testing

1. **Unit test in core:** Set `beforePublishHook` to a transformer, verify transformed events reach EventTopic. Set `afterPublishHook`, verify it's called after successful publish.
2. **Query interceptor test (in-memory):** Set `queryInterceptorHook` to deny, verify queries return null/empty.
3. **Query interceptor test (AWS):** Deploy with query interception enabled, verify queries go through the pipeline resolver and are denied without proper identity/claims.
4. **Existing tests:** All existing core tests must pass unchanged — hooks default to `None` (passthrough), so existing behavior is unaffected.

## Risks

- **Performance (event hooks):** Each publish gains two async hook calls. Mitigated: hooks are optional (`ref<option<...>>`), so when no hooks are set, the overhead is a single `switch None` — negligible.
- **Performance (AWS query interceptor):** Each query gains one Lambda invocation for the interceptor. Mitigated: interceptor Lambda is lightweight (single hook check), and can be bundled into an existing Lambda to share the cold start. Consider making pipeline resolvers conditional on interception being configured to eliminate overhead when not needed.
- **Error isolation:** A broken `afterPublishHook` must not fail the publish. Core wraps the call in try/catch and logs errors.
- **BeforePublish transformation:** A broken `beforePublishHook` must not corrupt events. If the hook throws, the original (untransformed) events are published.
- **AWS query interceptor latency:** Pipeline resolvers add ~10-50ms per query due to the extra Lambda invocation. For read-heavy workloads, consider caching authorization decisions or using VTL-only authorization where possible (e.g. Cognito group checks).
