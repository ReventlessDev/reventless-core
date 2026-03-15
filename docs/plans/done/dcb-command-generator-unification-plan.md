# DCB CommandGenerator Unification Plan

Wire CommandGenerator into the StateChangeSlice flow so DCB mutations return a message ID (like Aggregate mutations), and eliminate duplication between the two command-handling paths.

**Status: All steps completed (1–14)**

## Problem

1. **Aggregate mutations** go through CommandGenerator, which generates a `msgId` UUID and returns it to the caller.
2. **StateChangeSlice mutations** bypass CommandGenerator entirely — the GraphQL resolver builds a command body inline, dispatches directly to CommandTopic handlers, and returns a hardcoded `"ok"` string.
3. The two resolver files (`CommandGeneratorResolvers_GraphQL.res` and `DcbCommandTopicResolvers_GraphQL.res`) duplicate SDL derivation, command body construction, and GraphQL registration logic.

## Architecture (before → after)

### Before: Aggregate Flow
```
GraphQL mutation
  → CommandGeneratorResolvers_GraphQL (resolver stub)
  → CommandGenerator_Callback.generateCommand (creates msgId, builds {id, meta, commandJson})
  → CommandTopic.publishJsons
  → CommandTopic handler → Aggregate_Callback.handleCommands
```

### Before: StateChangeSlice Flow
```
GraphQL mutation
  → DcbCommandTopicResolvers_GraphQL (resolver, builds body inline, returns "ok")
  → CommandTopic.getHandlers(tag) → dispatches directly (bypasses bus)
  → StateChangeSlice_Builder.makeJsonHandler → StateChangeSlice_Callback.handleCommands
```

### After: Unified Flow
```
GraphQL mutation
  → CommandGeneratorResolvers_GraphQL (register for aggregates, registerDcb for DCB)
  → CommandGenerator_Callback.makeGenerateCommand (creates msgId, builds {id, meta, commandJson})
  → CommandTopic.publishJsons → bus
  → CommandTopic filtering handler → [Aggregate_Callback | StateChangeSlice handler]
```

## Implementation (completed)

### Step 1: Extract makeGenerateCommand as plain function ✅

**File**: `CommandGenerator_Callback.res`

Extracted the command generation logic from the `Make` functor into a standalone `makeGenerateCommand` function with explicit parameters (`~publishJsons`, `~serviceName`, `~commandSchema`, `~stripIdFromParams`). The existing `Make` functor now delegates to it.

This allows DCB code in `Dcb_Builder` to create `generateCommand` functions without requiring the full `AggregateSpec` + `Behavior` module types — just plain runtime values.

### Step 2: Add DCB support to unified resolver ✅

**File**: `CommandGeneratorResolvers_GraphQL.res` (in-memory)

Added `registerDcb(~fieldName, ~commandSchema)` for Phase 1 DCB mutation registration:
- Derives SDL via shared `deriveSdlField` helper without prepending `id: ID!`
- Extracts TAG from schema for command routing
- Finds tagged ID field via `DcbTag.isTagged` for entity ID extraction
- Creates resolver stub that maps tagged ID to `arguments.id` before calling `generateCommand` (skips when tagged field is already `"id"`)

Added `bindHandler(~field, ~generateCommand)` for Phase 2 direct binding of `generateCommand` to resolver stubs (used by DCB; aggregates continue using `handleResolversEvent` + `make`).

Both aggregate and DCB mutations share the same `handlerRefs` infrastructure and `extractVariantSchema`/`deriveSdlField` helpers.

### Step 3: Unified mutation resolver hooks ✅

**File**: `Plugin_Helpers.res`

Replaced three separate hooks (`aggregateMutationResolverHook`, `dcbMutationResolverHook`, `dcbMutationBindHook`) with two unified hooks using a `mutationKind` discriminator:

```rescript
type mutationKind = Aggregate | Dcb
let mutationResolverHook: ref<option<(~kind: mutationKind, ~fields: array<string>, ~commandSchema: S.t<unknown>) => unit>>
let mutationBindHook: ref<option<(~field: string, ~generateCommand: CommandGenerator.commandGenerator) => unit>>
```

Also added `dcbAppSyncResolverHook` for AWS DCB mutation AppSync resolver creation (modeled after `inboundAppSyncResolverHook`).

### Step 4: Wire CommandGenerator in Dcb_Builder ✅

**File**: `Dcb_Builder.res`

- Phase 1: Uses `mutationResolverHook(~kind=Dcb, ~fields=[fieldName], ~commandSchema)` per StateChangeSlice
- Phase 2: Uses `mutationBindHook` inside `Output.apply` to bind `generateCommand` (created via `makeGenerateCommand` with `~stripIdFromParams=false`)
- AWS: Collects field names + TAGs from all StateChangeSlices; calls `dcbAppSyncResolverHook` in `dcbConnectFn`

### Step 5: Update Platform hook wiring ✅

**File**: `Platform.res` (in-memory)

Single unified hook dispatcher:
```rescript
mutationResolverHook → dispatches by kind to register (Aggregate) or registerDcb (Dcb)
mutationBindHook → CommandGeneratorResolvers_GraphQL.bindHandler
```

**File**: `Plugin_Builder.res`

Updated to use `mutationResolverHook(~kind=Aggregate, ...)` instead of `aggregateMutationResolverHook`.

### Step 6: Fix filtering handler TAG extraction ✅

**File**: `CommandTopic_Builder.res`

`extractTypeNameFromJson` now checks `TAG` at top level first (backward compat), then falls back to `command.TAG` for messages that come through `publishJsons` → bus (where TAG is nested inside the `command` field).

### Step 7: Delete old DCB resolver ✅

**File**: `DcbCommandTopicResolvers_GraphQL.res` — **deleted**

All functionality absorbed into `CommandGeneratorResolvers_GraphQL.res`.

### Step 8: Fix LogFormat id quoting ✅

**File**: `LogFormat.res`

Changed `"id":${id}` to `"id":"${id}"` in `commandJsonToLogMessage` to match the event log format (`event'JsonToLogMessage`). Updated test expectations in `LogFormatTest.res`.

### Step 9: Extract shared SDL derivation helpers ✅

**File**: `CommandGeneratorResolvers_GraphQL.res` (in-memory)

Extracted `extractVariantSchema(commandSchema, ~index=0)` and `deriveSdlField(~fieldName, variantSchema)`. Both `register` and `registerDcb` use them, eliminating duplicate variant extraction and `deriveMutationFieldFromObject` calls.

### Step 10: Guard against tagged field named "id" ✅

**File**: `CommandGenerator_Callback.res`

Added `~stripIdFromParams: bool=true` parameter to `makeGenerateCommand`. Aggregates use default `true` (strips `id` from command params — required for zero-param commands that must be plain strings). DCB callers pass `~stripIdFromParams=false` (preserves all command fields including entity IDs).

**File**: `CommandGeneratorResolvers_GraphQL.res` (in-memory)

`registerDcb` skips adding synthetic `"id"` to args when `idFieldName == "id"` (the field is already present).

### Step 11: AWS AppSync DCB mutation resolvers ✅

**File**: `CommandGeneratorResolvers_AppSync.res` (AWS)

Added `makeDcb(~api, ~runtime, ~fieldNames, ~tags, ~opts)` — creates an AppSync DataSource + Resolver per DCB mutation field pointing to the shared DCB CommandTopic Lambda. Uses TAG-based VTL template (TAG from schema, not field name suffix) with `CommandGenerator.payload` format.

**File**: `Plugin_Helpers.res`

Added `dcbAppSyncResolverHook` with params `{runtime, fieldNames, tags, opts}`.

**File**: `Dcb_Builder.res`

Collects `(fieldName, tag)` pairs from StateChangeSlices. Calls `dcbAppSyncResolverHook` in `dcbConnectFn` when field names are present.

**File**: `Platform.res` (AWS)

Wires `dcbAppSyncResolverHook` to `CommandGeneratorResolvers_AppSync.makeDcb`.

**Note**: Step 11e (DCB Lambda dual-mode handler for AppSync direct invocations) is deferred — the existing aggregate CommandGenerator Lambda already handles `CommandGenerator.payload` format, so the DCB Lambda reuses the same pattern via `makeGenerateCommand`. Full dual-mode detection (AppSync vs SQS) will be needed when the DCB Lambda receives both event types in production.

### Step 12: Unify mutation resolver hooks ✅

**File**: `Plugin_Helpers.res`

Replaced `aggregateMutationResolverHook`, `dcbMutationResolverHook`, `dcbMutationBindHook` with:
- `mutationResolverHook(~kind: mutationKind, ~fields, ~commandSchema)` — Phase 1
- `mutationBindHook(~field, ~generateCommand)` — Phase 2

**Callers updated**: `Plugin_Builder.res` (aggregates), `Dcb_Builder.res` (DCB), `Platform.res` (in-memory).

**Note**: Aggregate Phase 2 still goes through the adapter-driven `handleResolversEvent` + `make` path. Full Phase 2 unification (aggregates also using `mutationBindHook`) would require changing `AggregateRuntime_Builder.forCommandGenerator` — deferred as a separate refactor.

## Completed Steps (continued)

### Step 13: Aggregate Phase 2 unification via mutationBindHook ✅

Aggregates still use the adapter-driven `handleResolversEvent` + `Resolvers.make` path for Phase 2 binding. This step unifies them to use `mutationBindHook`, eliminating the separate `pending` ref / `handleResolversEvent` / `make` machinery in `CommandGeneratorResolvers_GraphQL.res`.

#### Current Aggregate Phase 2 Flow

```
Aggregate_Builder.createCommandGenerator
  → SpecificCommandGenerator.makeHandler(~publishJsons)
      → CommandGenerator_Callback.Make(publishJsons, Spec, Behavior)  // creates generateCommand
      → Resolvers.handleResolversEvent(generateCommand)               // stores in pending ref
  → AggregateRuntimeBuilder.forCommandGenerator(~handler, ~connect)
      → RuntimeEnvironment.make(~handler)                             // wraps handler as runtime
      → connect(~runtime)
          → CommandGenerator_Builder.connect(~api, ~resources, ~runtime, commandGenerator)
              → Resolvers.make(~fields, ~commandSchema, ~runtime, ...)  // consumes pending ref, binds to stubs
```

In the in-memory adapter, `Resolvers` = `CommandGeneratorResolvers_GraphQL`:
- `handleResolversEvent`: stores `generateCommand` in `pending` ref, returns Output handler
- `make`: consumes `pending`, iterates `fields`, sets `handlerRef.contents` per field

This is functionally identical to what `mutationBindHook` → `bindHandler` already does.

#### Target Aggregate Phase 2 Flow

```
Aggregate_Builder.createCommandGenerator
  → CommandGenerator_Callback.makeGenerateCommand(~publishJsons, ~serviceName, ~commandSchema)
  → Plugin_Helpers.mutationBindHook(~field, ~generateCommand)  // per field
```

No runtime creation needed for the CommandGenerator — it only exists to bind the resolver stubs.

#### Implementation (completed)

**Approach B** implemented: `Aggregate_Builder.createCommandGenerator` checks `mutationBindHook`. When set (in-memory), it calls `makeGenerateCommand` and binds directly to resolver stubs via the hook, skipping `forCommandGenerator` entirely. When unset (AWS), the existing adapter-driven path (`forCommandGenerator` → Lambda + policies) runs unchanged.

**File**: `Aggregate_Builder.res`

In `createCommandGenerator`, after creating the component via `SpecificCommandGenerator.make`, the function branches:
- `Some(bindHandler)`: resolves field names from `aggregateMutationFieldsRegistry` (or falls back to `Behavior.resolverConfig.fields`), creates `generateCommand` via `CommandGenerator_Callback.makeGenerateCommand`, and binds each field.
- `None`: original path — calls `AggregateRuntimeBuilder.forCommandGenerator` with `makeHandler` and `connect`.

**Files unchanged**: `CommandGeneratorResolvers_GraphQL.res` (in-memory) — `handleResolversEvent`, `pending`, and `make` retained for AWS path compatibility (they satisfy `CommandGenerator_Adapter.Resolvers` module type used by `CommandGenerator_Builder`).

### Step 14: DCB Lambda dual-mode handler for AppSync invocations ✅

The DCB CommandTopic Lambda currently only processes bus messages (SQS in AWS, in-memory bus events). With Step 11's AppSync resolvers, the Lambda also receives direct invocations with `CommandGenerator.payload` format (`{command, arguments, meta}`). The handler needs dual-mode detection.

#### Current DCB Lambda Handler Chain (AWS)

```
SQS event → Lambda
  → RuntimeEnvironment.Lambda handler
  → CommandTopicChannel_SQS_Runtime.handleChannelEvent
      → Extracts SQS body → JSON
  → Composite handler (from Dcb_Builder)
      → Check __inboundTranslation? → InboundTranslation receiver
      → Else → filteringHandler → CommandTopic.getHandlers(TAG) → StateChangeSlice handler
```

The SQS event has `Records` array format. An AppSync direct invocation has `CommandGenerator.payload` format.

#### Target Dual-Mode Handler

```
Event → Lambda
  → Detect event format:
      SQS?      → existing composite handler chain
      AppSync?  → makeGenerateCommand → publishJsons → return msgId
```

#### Implementation (completed)

**File**: `Dcb_Builder.res`

Added `dcbGenerateCommandOutput` — a shared `generateCommand` created from the DCB CommandTopic's `publishJsons`, using `S.json` as a permissive commandSchema (AppSync already validates input against the SDL, so double-validation is redundant). `~stripIdFromParams=false` preserves all command fields.

The composite handler now resolves three outputs via `Pulumi.Output.all3` (was `all2`): `baseHandler`, `receivers`, and `generateCommand`. The tri-mode detection:
1. `__inboundTranslation` present → InboundTranslation receiver (unchanged)
2. `command` is a `JSON.String` + `arguments` present → AppSync direct invocation → `generateCommand(payload)` returns msgId
3. Otherwise → `baseHandler` (SQS/bus event)

## Files Changed

| File | Steps | Action | Description |
|------|-------|--------|-------------|
| `CommandGenerator_Callback.res` | 1, 10 | **Modify** | Extract `makeGenerateCommand` with `~stripIdFromParams` param |
| `CommandGeneratorResolvers_GraphQL.res` (in-memory) | 2, 9, 10 | **Modify** | Add `registerDcb`, `bindHandler`, shared SDL helpers |
| `Plugin_Helpers.res` | 3, 11, 12 | **Modify** | Unified `mutationResolverHook`/`mutationBindHook`, `dcbAppSyncResolverHook` |
| `Dcb_Builder.res` | 4, 11, 12 | **Modify** | Wire `generateCommand`, AppSync hook, unified hooks |
| `Plugin_Builder.res` | 12 | **Modify** | Use unified `mutationResolverHook` |
| `CommandTopic_Builder.res` | 6 | **Modify** | Fix TAG extraction for nested `{command: {TAG, ...}}` |
| `Platform.res` (in-memory) | 5, 12 | **Modify** | Unified hook dispatcher |
| `DcbCommandTopicResolvers_GraphQL.res` (in-memory) | 7 | **Delete** | Absorbed into unified resolver |
| `LogFormat.res` | 8 | **Modify** | Quote `id` in command log format |
| `LogFormatTest.res` | 8 | **Modify** | Update expected strings |
| `CommandGeneratorResolvers_AppSync.res` (AWS) | 11 | **Modify** | Add `makeDcb` for DCB AppSync resolvers |
| `Platform.res` (AWS) | 11 | **Modify** | Wire `dcbAppSyncResolverHook` |

## Files Changed (Steps 13–14)

| File | Step | Action | Description |
|------|------|--------|-------------|
| `Aggregate_Builder.res` | 13 | **Modify** | Add `mutationBindHook` branch in `createCommandGenerator`, skip `forCommandGenerator` in in-memory |
| `CommandGeneratorResolvers_GraphQL.res` (in-memory) | 13 | **No change** | `handleResolversEvent`/`pending`/`make` kept for AWS compat |
| `Dcb_Builder.res` | 14 | **Modify** | Create shared `dcbGenerateCommand`, add direct invocation detection in composite handler |

## Migration Notes

- **Breaking change for DCB mutation callers**: Return value changes from `"ok"` to a UUID string. Callers that check `=== "ok"` will break.
- **Non-breaking for Aggregate callers**: No change in behavior.
