# Backlog: Effect-Based Handlers

## Goal

Convert `Runtime.eventHandler` from `async` functions to `Effect.t` pipelines, enabling natural `'r` propagation for both Logger and RequestContext services.

## Current State

- `Runtime.eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>` — plain async functions
- Logger is injected via `Runtime.runtimeLogger` (synchronous, called directly in handler dispatch code)
- `RequestContext` type and tag exist in `reventless-core/src/RequestContext.res` but aren't used anywhere
- Handler callbacks (Aggregate_Callback, CommandTopic_Callback, etc.) are all async functions

## Why This Matters

With Effect-based handlers:
- **Logger via `'r`**: Handler code can use `Effect.serviceWith(Logger.tag, logger => logger.info(...))` instead of direct Console calls — automatically provided by the runtime
- **RequestContext via `'r`**: Each handler invocation can carry request-scoped context (correlation ID, tenant, user) through the Effect environment without explicit parameter threading
- **Structured concurrency**: Effect's fiber model gives better error handling, cancellation, and resource management than raw async/await

## Prerequisites

1. All handler callbacks need Effect return types: `('event, 'context) => Effect.t<'result, 'error, 'r>`
2. Runtime builders need to `Effect.provideService` Logger and RequestContext before running each handler
3. The in-memory bus dispatch and AWS Lambda entry points need Effect-aware wrappers

## Migration Strategy

### Phase 1: Dual-mode handlers
- Add `Effect.t` variants of handler types alongside existing async ones
- New components can opt into Effect handlers; existing ones continue with async

### Phase 2: Convert callbacks
- Migrate handler callbacks one component at a time: Aggregate, CommandTopic, EventCollector, StateChangeSlice, etc.
- Each migration is independent and testable

### Phase 3: Wire `'r` services
- Runtime builders provide Logger and RequestContext via `Effect.provideService` at handler entry points
- Remove manual logger passing from `Runtime.Environment`

### Phase 4: Remove async handlers
- Once all callbacks are Effect-based, remove the async handler type
- Simplify runtime builders

## Affected Files

- `reventless-core/src/adapter/Runtime/Runtime.res` — handler type definitions
- `reventless-core/src/adapter/Runtime/AggregateRuntime_Builder_Common.res` — handler dispatch
- `reventless-core/src/adapter/Runtime/EventCollectorRuntime_Builder_Single.res` — handler dispatch
- `reventless-core/src/components/Aggregate/Aggregate_Callback.res`
- `reventless-core/src/components/CommandTopic/CommandTopic_Callback.res`
- `reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res`
- `reventless-core/src/components/EventCollector/EventCollector_Callback.res` (if exists)
- `reventless-in-memory/src/adapter/Runtime/RuntimeEnvironment_InMemory.res`
- `reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res`

## Scope

This is a significant architectural change affecting the entire handler pipeline. Should be done incrementally with thorough testing at each phase.
