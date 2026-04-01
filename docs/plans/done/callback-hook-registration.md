# Callback Hook Registration API

## Context

The four callback hooks (`commandInterceptorHook`, `queryInterceptorHook`, `beforePublishHook`, `afterPublishHook`) are currently exposed as bare `ref<option<callback>>` values. External code sets them by writing directly to `.contents`:

```rescript
CommandGenerator_Callback.commandInterceptorHook.contents = Some(myInterceptor)
```

This is fragile — consumers directly mutate module-level state with no encapsulation. A `register` / `clear` API is cleaner and matches the pattern already used by the SDK's internal pipelines (`CommandPipeline.register`, `EventHookOrchestrator.register`).

---

## Status

| Step | Description | Status |
|------|-------------|--------|
| 1 | Add register/clear API to `CommandGenerator_Callback` | done |
| 2 | Add register/clear API to `QueryDb_Callback` | done |
| 3 | Add register/clear API to `EventPublish_Callback` | done |
| 4 | Update internal readers to use the same refs (no change needed) | done (verified) |
| 5 | Validate core builds + tests pass | done (252/252 tests pass) |

---

## Step 1 — `CommandGenerator_Callback`

**File:** `reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res`

Before:
```rescript
let commandInterceptorHook: ref<option<commandInterceptor>> = ref(None)
```

After:
```rescript
let commandInterceptorHook: ref<option<commandInterceptor>> = ref(None)

let registerCommandInterceptor = (interceptor: commandInterceptor) => {
  commandInterceptorHook.contents = Some(interceptor)
}

let clearCommandInterceptor = () => {
  commandInterceptorHook.contents = None
}
```

The `ref` stays (internal readers still use `switch commandInterceptorHook.contents`). The register/clear functions provide the public API. The bare `ref` can be marked as internal or left accessible for backward compatibility.

**Readers (no change needed):**
- `CommandGenerator_Callback.res:80` — `switch commandInterceptorHook.contents` stays as-is. It reads the same ref.

## Step 2 — `QueryDb_Callback`

**File:** `reventless-core/src/components/QueryDb/QueryDb_Callback.res`

Same pattern:
```rescript
let registerQueryInterceptor = (interceptor: queryInterceptor) => {
  queryInterceptorHook.contents = Some(interceptor)
}

let clearQueryInterceptor = () => {
  queryInterceptorHook.contents = None
}
```

**Readers (no change needed):**
- `QueryInterceptor_Lambda.res:8` — reads `queryInterceptorHook.contents`
- `QueryDbResolvers_GraphQL.res:46` — reads `queryInterceptorHook.contents`

## Step 3 — `EventPublish_Callback`

**File:** `reventless-core/src/components/EventLog/EventPublish_Callback.res`

```rescript
let registerBeforePublish = (hook: beforePublishHook) => {
  beforePublishHook.contents = Some(hook)
}

let registerAfterPublish = (hook: afterPublishHook) => {
  afterPublishHook.contents = Some(hook)
}

let clearPublishHooks = () => {
  beforePublishHook.contents = None
  afterPublishHook.contents = None
}
```

**Readers (no change needed):**
- `EventLog_Operations.res:66,82` — reads both hooks
- `DcbEventLog_Operations.res:27,62` — reads both hooks
- `ExtensionPoint_Operations.res:52,86` — reads both hooks

## Step 4 — Verify internal readers

All readers use `switch hookRef.contents { | Some(fn) => ... | None => ... }`. Since the ref itself doesn't change (only its contents), no reader needs updating. This step is just verification — grep for all `.contents` accesses and confirm they still compile.

## Step 5 — Validate

Build core and run all tests. The new functions are additive — no existing code breaks.

---

## Notes

- The `ref` values stay accessible for now. Making them truly private would require a `.resi` interface file that hides them. That's a follow-up if desired.
- The single-slot semantic is preserved — `register` overwrites the previous hook. This is intentional (see [callback-hooks-and-adapter-wrapping.md](../guides/callback-hooks-and-adapter-wrapping.md) for rationale).
- The naming convention (`registerCommandInterceptor`, `registerQueryInterceptor`, `registerBeforePublish`, `registerAfterPublish`) matches the concept: you're registering a single callback, not adding to a list.
