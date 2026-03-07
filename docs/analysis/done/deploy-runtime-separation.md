# Analysis: Deploy-Time vs Runtime Separation in Provider Packages

## Status: Analysis Complete

## Problem Statement

The reventless-aws and reventless-in-memory adapter packages both contain deploy-time (Pulumi infrastructure) and runtime (handler/business logic) code, but the boundary between the two is not consistently clear. This analysis examines the current state and proposes options for making the separation more explicit.

## Current State

### AWS Adapter (`reventless-aws/src/adapter/`)

The AWS adapter has a **clear naming convention** that separates deploy-time from runtime:

```
adapter/
  EventLog/
    EventLogStorage.res                        # namespace
    EventLogStorage_DynamoDb.res               # DEPLOY-TIME - creates DynamoDB table
    EventLogStorage_DynamoDb_Runtime.res        # RUNTIME - DynamoDB SDK operations
    EventLogStorage_DynamoDbStream.res          # DEPLOY-TIME - stream piping (no Runtime)
  CommandTopic/
    CommandTopicChannel.res                     # namespace
    CommandTopicChannel_SQS.res                # DEPLOY-TIME - creates SQS queue, wires Lambda
    CommandTopicChannel_SQS_Runtime.res         # RUNTIME - SQS message handling
    CommandTopicChannel_SQS_FIFO.res           # DEPLOY-TIME - FIFO queue variant
    CommandTopicChannel_Helpers.res            # MIXED - IAM/subscription helpers
    CommandTopicRemoteChannel.res              # namespace
    CommandTopicRemoteChannel_SQS.res          # DEPLOY-TIME
  EventCollector/
    EventCollectorChannel.res                  # namespace
    EventCollectorChannel_SQS.res              # DEPLOY-TIME
    EventCollectorChannel_SQS_Runtime.res      # RUNTIME
    EventCollectorChannel_SQS_FIFO.res         # DEPLOY-TIME
    EventCollectorChannel_DynamoDbStream.res   # DEPLOY-TIME
    EventCollectorChannel_DynamoDbStream_Runtime.res  # RUNTIME
    EventCollectorChannel_Helpers.res          # MIXED
  EventTopic/
    EventTopicPublisher.res                    # namespace
    EventTopicPublisher_SNS.res                # DEPLOY-TIME
    EventTopicPublisher_SNS_Runtime.res        # RUNTIME (minimal, delegates to util)
    EventTopicPublisher_SNS_FIFO.res           # DEPLOY-TIME
    EventTopicPublisher_DynamoDbStream.res     # DEPLOY-TIME
  QueryDb/
    QueryDbStorage.res                         # namespace
    QueryDbStorage_DynamoDb.res                # DEPLOY-TIME
    QueryDbStorage_DynamoDb_Runtime.res        # RUNTIME
    QueryDbStorage_DynamoDbStream.res          # DEPLOY-TIME
    QueryDbResolvers.res                       # namespace
    QueryDbResolvers_AppSync.res               # DEPLOY-TIME
    QueryDbResolvers_NoOp.res                  # DEPLOY-TIME
  Counter/
    CounterHandler_DynamoDbStream.res          # DEPLOY-TIME
    CounterHandler_DynamoDbStream_Runtime.res  # RUNTIME
  DcbEventLog/
    DcbEventLogStorage.res                     # namespace
    DcbEventLogStorage_DynamoDb.res            # DEPLOY-TIME
    DcbEventLogStorage_DynamoDb_Runtime.res    # RUNTIME
  Task/
    TaskBucket.res                             # namespace
    TaskBucket_S3.res                          # DEPLOY-TIME
    TaskBucket_S3_Runtime.res                  # RUNTIME
  CommandGenerator/
    CommandGeneratorResolvers.res              # namespace
    CommandGeneratorResolvers_AppSync.res       # DEPLOY-TIME
    CommandGeneratorResolvers_AppSync_Runtime.res  # RUNTIME
  Heartbeat/
    HeartbeatRunner.res                        # namespace
    HeartbeatRunner_CloudWatchEvents.res       # DEPLOY-TIME
  ScheduledPublisher/
    ScheduledPublisher.res                     # namespace
    ScheduledPublisher_CloudWatchEvents.res    # DEPLOY-TIME
    ScheduledPublisher_CloudWatchEvents_Runtime.res  # RUNTIME
  StateTopic/
    StateTopicPublisher.res                    # namespace
    StateTopicPublisher_DynamoDbStream.res     # DEPLOY-TIME
  Cloner/
    ClonerRunner.res                           # namespace
    ClonerRunner_Fargate.res                   # DEPLOY-TIME
    ClonerRunner_Fargate_Runtime.res           # RUNTIME
  Runtime/
    RuntimeEnvironment.res                     # namespace
    RuntimeEnvironment_Lambda.res              # DEPLOY-TIME - Lambda function creation
  Mcp/
    MCP_Lambda.res                             # MIXED
  Adapter_Helpers.res                          # MIXED
  AWS.res                                      # MIXED - SDK re-exports
  AWS_Tags.res                                 # MIXED - tag factory
```

**Pattern:** `Component_Provider.res` (deploy) + `Component_Provider_Runtime.res` (runtime)

**Verdict:** The `_Runtime` suffix convention works well. The separation is file-level and consistent across most components. The main issue is that some "MIXED" files exist (`Helpers`, `AWS.res`) and a few components have no Runtime file when they delegate to streams.

### In-Memory Adapter (`reventless-in-memory/src/adapter/`)

The in-memory adapter has **no deploy/runtime separation** — each component is a single file:

```
adapter/
  EventLog/
    EventLogStorage_InMemory.res               # MIXED - make() + Stm.TRef operations
  CommandTopic/
    CommandTopicChannel_InMemory.res            # MIXED - make() + Bus dispatch
    CommandTopicRemoteChannel_InMemory.res      # MIXED
  EventCollector/
    EventCollectorChannel_InMemory.res          # MIXED - make() + Bus subscribe
  EventTopic/
    EventTopicPublisher_InMemory.res            # MIXED - make() + Bus publish
  QueryDb/
    QueryDbStorage_InMemory.res                # MIXED - make() + in-memory KV store
    QueryDbResolvers_GraphQL.res               # DEPLOY-TIME - GraphQL schema
  Counter/
    CounterHandler_InMemory.res                # MIXED
  DcbEventLog/
    DcbEventLogStorage_InMemory.res            # MIXED
  Task/
    TaskBucket_InMemory.res                    # MIXED
  CommandGenerator/
    CommandGeneratorResolvers_InMemory.res      # MIXED
    CommandGeneratorResolvers_GraphQL.res       # DEPLOY-TIME
    DcbCommandTopicResolvers_GraphQL.res        # DEPLOY-TIME
    InboundTranslationResolvers_GraphQL.res     # DEPLOY-TIME
  Heartbeat/
    HeartbeatRunner_InMemory.res               # MIXED
  Scheduler/
    ScheduledPublisher_InMemory.res            # MIXED
  Cloner/
    ClonerRunner_InMemory.res                  # MIXED
  Runtime/
    RuntimeEnvironment_InMemory.res            # MIXED
    AggregateRuntime_Builder_InMemory.res      # DEPLOY-TIME
    EventCollectorRuntime_Builder_InMemory.res # DEPLOY-TIME
    PluginRuntime_Builder_InMemory.res         # DEPLOY-TIME
  Api/
    GraphQL_InMemory_Adapter.res               # DEPLOY-TIME
  GraphQL_Server.res                           # RUNTIME
  InMemory_Bus.res                             # MIXED
  InMemory_PluginSpec.res                      # MIXED
  MCP_Server.res                               # RUNTIME
  SideEffectHandler_InMemory.res               # RUNTIME
```

**Pattern:** Single `Component_InMemory.res` file handles both deploy-time `make()` and runtime logic.

**Verdict:** The in-memory package naturally has less infrastructure, but the deploy/runtime boundary still exists conceptually. The `make()` function is deploy-time (creates Pulumi-wrapped operations), while the actual storage/dispatch logic is runtime. These are interleaved in the same file.

### Base Adapter Interfaces (`reventless/src/adapter/`)

```
adapter/
  Adapter.res                                  # MIXED - Output/resource conversions
  AdapterDeploytime.res                        # DEPLOY-TIME - StackReference handling
  Runtime/
    AggregateRuntime_Builder.res               # DEPLOY-TIME - module type
    AggregateRuntime_Builder_Common.res        # DEPLOY-TIME
    AggregateRuntime_Builder_Single.res        # DEPLOY-TIME
    AggregateRuntime_Builder_Micro.res         # DEPLOY-TIME
    AggregateRuntime_Builder_PerAggregate.res  # DEPLOY-TIME
    EventCollectorRuntime_Builder.res          # DEPLOY-TIME
    EventCollectorRuntime_Builder_Single.res   # DEPLOY-TIME
    EventCollectorRuntime_Builder_PerEventCollector.res  # DEPLOY-TIME
    ExtensionPointRuntime_Builder.res          # DEPLOY-TIME
    ExtensionPointRuntime_Builder_PerExtensionPoint.res  # DEPLOY-TIME
    PluginRuntime_Builder.res                  # DEPLOY-TIME
    PluginRuntime_Builder_Single.res           # DEPLOY-TIME
    PluginRuntime_Builder_Micro.res            # DEPLOY-TIME
    TaskRuntime_Builder.res                    # DEPLOY-TIME
    TaskRuntime_Builder_PerBucket.res          # DEPLOY-TIME
    Runtime.res                                # MIXED - type definitions
```

**Verdict:** The `Runtime/` subfolder name is misleading — these are all deploy-time orchestration builders, not runtime code. The name "Runtime" here refers to "the runtime _environment_ builder" (i.e., building the Lambda/handler infrastructure), not code that runs at runtime.

## Naming Inconsistencies

| Issue | AWS | In-Memory | Impact |
|-------|-----|-----------|--------|
| Runtime file separation | Explicit `_Runtime.res` suffix | No separation — mixed in single file | Hard to know which in-memory code is deploy vs runtime |
| Namespace files | `Component.res` per folder | No namespace files | Minor — in-memory has fewer variants |
| Helper files | `_Helpers.res` suffix | None | AWS-specific concern |
| Scheduler folder name | `ScheduledPublisher/` | `Scheduler/` | Inconsistent folder naming for the same component |
| GraphQL files location | Under `CommandGenerator/` | Under `CommandGenerator/` + root + `Api/` | In-memory has GraphQL files scattered across locations |
| `SideEffectHandler` | Not present | Root-level file | Asymmetric — only exists in in-memory |
| `GraphQL_Server` | Not present | Root-level file | In-memory only concern |
| Bus module | Not applicable | Root-level `InMemory_Bus.res` | In-memory specific infrastructure |

## Options for Improvement

### Option A: Two Subtrees (deploy / runtime)

Split each adapter folder into two top-level subtrees:

```
adapter/
  deploy/
    EventLog/
      EventLogStorage_DynamoDb.res
    CommandTopic/
      CommandTopicChannel_SQS.res
      CommandTopicChannel_SQS_FIFO.res
    ...
  runtime/
    EventLog/
      EventLogStorage_DynamoDb.res     # was _Runtime.res
    CommandTopic/
      CommandTopicChannel_SQS.res      # was _Runtime.res
    ...
```

**Pros:**
- Very clear physical separation
- Easy to understand at a glance which code runs where
- Could enable different build/bundling for deploy vs runtime

**Cons:**
- Breaks the current convention where related deploy+runtime files sit next to each other
- Duplicates the folder structure (EventLog/, CommandTopic/, etc. appears twice)
- File names become ambiguous — `EventLogStorage_DynamoDb.res` exists in both subtrees
- Large refactor affecting all import paths
- Makes it harder to work on a single component (files scattered across two trees)

### Option B: Suffix Convention (current AWS pattern, extended to in-memory)

Keep the current folder structure. Formalize and extend the `_Runtime` suffix convention to in-memory:

```
# AWS stays as-is (already follows the convention)
adapter/
  EventLog/
    EventLogStorage_DynamoDb.res            # deploy-time
    EventLogStorage_DynamoDb_Runtime.res    # runtime

# In-memory: split mixed files into deploy + runtime
adapter/
  EventLog/
    EventLogStorage_InMemory.res            # deploy-time (make function)
    EventLogStorage_InMemory_Runtime.res    # runtime (Stm.TRef operations)
  CommandTopic/
    CommandTopicChannel_InMemory.res        # deploy-time
    CommandTopicChannel_InMemory_Runtime.res # runtime (Bus dispatch)
```

**Pros:**
- Minimal disruption to AWS adapter (already works this way)
- Related files stay next to each other
- Clear naming convention: no `_Runtime` suffix = deploy-time, `_Runtime` suffix = runtime
- Consistent across both packages

**Cons:**
- In-memory runtime files may be very small (since there's no real infrastructure)
- Some in-memory components have trivial runtime logic that doesn't benefit from separation
- Still need to decide what to do with "MIXED" utility files

### Option C: Module-Level Separation (deploy + Runtime submodule)

Keep single files but use ReScript module structure to separate concerns:

```rescript
// EventLogStorage_InMemory.res

// Deploy-time: creates component with Pulumi-wrapped operations
let make = (~name, ~opts=?) => {
  // ... Pulumi resource creation
}

module Runtime = {
  // Runtime: actual storage operations
  let append = (store, events) => { ... }
  let replay = (store, id) => { ... }
}
```

**Pros:**
- No file proliferation
- Clear separation within each file
- Easy to enforce via code review
- Works naturally with ReScript's module system

**Cons:**
- Less visible at the file-system level
- Doesn't help with build-time separation (can't tree-shake deploy code from runtime bundle)
- Harder to enforce consistency — relies on discipline
- AWS adapter already has separate files, creating divergence between packages

### Option D: Hybrid — Suffix Convention + Rename Confusing Folders

Combine Option B with targeted folder/file renames to fix inconsistencies:

1. **Extend `_Runtime` suffix to in-memory** (Option B)
2. **Rename `Scheduler/` to `ScheduledPublisher/`** in in-memory (match AWS)
3. **Rename base `adapter/Runtime/` to `adapter/RuntimeBuilder/`** to avoid confusion (these are deploy-time builders, not runtime code)
4. **Add namespace files to in-memory** where multiple variants exist (e.g., `CommandGeneratorResolvers.res`)
5. **Consolidate scattered GraphQL files** in in-memory under a consistent location

```
# Base adapter (reventless)
adapter/
  Adapter.res
  AdapterDeploytime.res
  RuntimeBuilder/                              # renamed from Runtime/
    AggregateRuntime_Builder.res
    ...

# AWS adapter (no structural changes, already consistent)
adapter/
  EventLog/
    EventLogStorage.res
    EventLogStorage_DynamoDb.res
    EventLogStorage_DynamoDb_Runtime.res
  ...

# In-memory adapter (split mixed files, rename inconsistencies)
adapter/
  EventLog/
    EventLogStorage_InMemory.res               # deploy-time only
    EventLogStorage_InMemory_Runtime.res        # runtime operations
  CommandTopic/
    CommandTopicChannel_InMemory.res            # deploy-time
    CommandTopicChannel_InMemory_Runtime.res    # runtime
  ScheduledPublisher/                          # renamed from Scheduler/
    ScheduledPublisher_InMemory.res
    ScheduledPublisher_InMemory_Runtime.res
  RuntimeBuilder/                              # renamed from Runtime/
    RuntimeEnvironment_InMemory.res
    AggregateRuntime_Builder_InMemory.res
    ...
```

## Recommendation

**Option D (Hybrid)** provides the best balance:

- It builds on the existing AWS convention (`_Runtime` suffix) rather than inventing something new
- It fixes the real inconsistencies (folder names, scattered files) without a large restructure
- It makes both packages follow the same pattern, so developers moving between them know what to expect
- The rename of `Runtime/` to `RuntimeBuilder/` eliminates the confusing overload of "Runtime" (deploy-time builder vs actual runtime code)

The key insight is that the AWS adapter already has a good convention — the work is mostly about extending it to the in-memory adapter and fixing a few naming inconsistencies.

## Impact Assessment

### Files affected (Option D)

**Base adapter (`reventless/src/adapter/`):**
- Rename `Runtime/` folder to `RuntimeBuilder/` (affects ~15 files + all imports)

**In-memory adapter (`reventless-in-memory/src/adapter/`):**
- Split ~12 mixed files into deploy + runtime pairs
- Rename `Scheduler/` to `ScheduledPublisher/`
- Rename `Runtime/` to `RuntimeBuilder/`
- Move/consolidate scattered GraphQL files

**AWS adapter (`reventless-aws/src/adapter/`):**
- Rename `Runtime/` to `RuntimeBuilder/` (2 files)
- No other structural changes needed

### Risk

- Medium: import path changes across the monorepo
- Low: no logic changes, purely organizational
- Mitigated by: ReScript compiler will catch all broken imports at build time
