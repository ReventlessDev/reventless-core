# Plan: File-Level Separation of Helpers in ReScript Binding Packages

**Based on**: [analysis/rescript-bindings-helpers-split.md](../analysis/rescript-bindings-helpers-split.md)

## Goal

Extract helper functions from mixed binding files into separate `*_Helpers.res` files within the same package. No new packages — just file-level separation for clarity.

## Scope

Only 6 packages have helpers to extract. 7 packages (rescript-pulumi-aws, rescript-node-streams, rescript-node-zlib, rescript-graphql-yoga, rescript-hash-object, rescript-uuid, rescript-ssh2) are already pure bindings and need no changes.

Within rescript-effect, only 3 of 19 files have helpers (Effect.res, Fiber.res, Stream.res). The other 16 files are pure bindings.

## Convention

- Helper files are named `<Module>_Helpers.res` and placed alongside the binding file in `src/`
- Helper files reference the binding module by name to access types (e.g., `S3.client`, `SQS.SendMessageBatchCommand.sendMessageBatchEntry`)
- Binding files retain all types, `@module`/`@val`/`@send`/`@new` externals, and internal raw bindings needed by helpers
- Re-exports from the binding module are NOT added (consumers use `S3_Helpers.upload()` directly)
- Client singletons and `.send` wrappers inside submodules stay in the binding file (they're tightly coupled and moving them would create circular dependencies)

## Implementation Notes

- **Client singletons** (`client()` in S3, SNS, SQS) kept in binding files because submodule `.send` wrappers depend on them, and moving both would break the submodule API
- **Immutable wrappers** in MomentRe.Moment module kept in binding file because they're inside a submodule that can't be split across files in ReScript
- **MarshallOptions** phantom-type module in DynamoDb_Util kept in binding file because it's a sealed module with type constraints
- **Internal bindings** (e.g., `_tryPromiseRaw`, `paginateEffectRaw`, `chunkFromIterable`) kept in binding files; helpers reference them via qualified names

## Steps

### Step 1: rescript-aws-sdk — S3_Helpers.res
- [x] Create `src/S3_Helpers.res`
- [x] Move from `S3.res`: `Upload.options` type, `Upload.make` factory, `upload` convenience function
- [x] Keep in `S3.res`: `clientInstance`, `client()`, all types, `Raw` externals, `.send` wrappers, `Upload.Raw`, `Upload.done`

### Step 2: rescript-aws-sdk — SNS_Helpers.res
- [x] Create `src/SNS_Helpers.res`
- [x] Move from `SNS.res`: `publish`, `findSubscription`, `subscribeQueueToTopic`, `unsubscribeQueueFromTopic`
- [x] Keep in `SNS.res`: `clientInstance`, `client()`, all types, `Raw` externals, command constructors, `.send` wrappers

### Step 3: rescript-aws-sdk — SQS_Helpers.res
- [x] Create `src/SQS_Helpers.res`
- [x] Move from `SQS.res`: `arn2Url`, `sendMessage`, `validateDelay`, `makeBatchEntry`/`makeBatchEntryFifo`, `maxBatchMessages`/`maxBatchBytes`, `handleSendBatchPromises`, `handleBatchResult`, `sendMessagesParallel`, `handleDeleteBatchPromises`, `deleteMessagesParallel`, `getQueuePolicy`, `setQueuePolicy`
- [x] Keep in `SQS.res`: `clientInstance`, `client()`, all types, `Raw` externals, command constructors, `.send` wrappers

### Step 4: rescript-aws-sdk — DynamoDb_Util_Helpers.res
- [x] Create `src/DynamoDb_Util_Helpers.res`
- [x] Move from `DynamoDb_Util.res`: `unmarshallDict` and `unmarshall` wrappers
- [x] Keep in `DynamoDb_Util.res`: `attributeValue` type, `MarshallOptions` module (sealed with phantom types), `Raw` module, `marshall` external

### Step 5: rescript-aws-sdk — update consumers
- [x] Update `AwsSdk.SNS.publish` → `AwsSdk.SNS_Helpers.publish` (and subscribeQueueToTopic, unsubscribeQueueFromTopic)
- [x] Update `SQS.sendMessage` → `SQS_Helpers.sendMessage` (and makeBatchEntry, sendMessagesParallel, deleteMessagesParallel)
- [x] Update `AwsSdk.SQS.sendMessage` → `AwsSdk.SQS_Helpers.sendMessage`

### Step 6: rescript-fast-csv — FastCSV_Helpers.res
- [x] Create `src/FastCSV_Helpers.res`
- [x] Move from `FastCSV.res`: `toInvalid`/`toValid`/`toError`, `toValidTransformation`/`toErrorTransformation`, `validateMultiple`, `fromImporterValidation`, `validateResult`, `validateMultipleResults`
- [x] Keep in `FastCSV.res`: all types, `Options` module, streaming/event externals, `makeError` external
- [x] No consumers found in this repo

### Step 7: rescript-moment — MomentRe_Helpers.res
- [x] Create `src/MomentRe_Helpers.res`
- [x] Move from `MomentRe.res`: duration construction wrappers, moment construction wrappers, `momentWithUnix`, format-selection helpers `moment`/`momentUtc`
- [x] Keep in `MomentRe.res`: `Duration` module, `Moment` module (including immutable wrappers — they're inside the submodule), raw `_duration*`/`_moment*` externals, `diff`/`diffWithPrecision` externals
- [x] No consumers found in this repo (consumers are in reventless-ui repo)

### Step 8: rescript-pulumi-pulumi — Output_Helpers.res
- [x] Create `src/Output_Helpers.res`
- [x] Move from `Output.res`: `allOpt`, `flatMap`, `unzip`/`unzip3`, `zip`/`zip3` aliases
- [x] Keep in `Output.res`: all core externals (`make`, `apply`, `map`, `all*`, `unwrap`, etc.)
- [x] Update all consumer references (`Pulumi.Output.flatMap` → `Pulumi.Output_Helpers.flatMap`, etc.)

### Step 9: rescript-effect — Effect_Helpers.res, Fiber_Helpers.res, Stream_Helpers.res
- [x] Create `src/Effect_Helpers.res`, move: `tryPromise`, `trySync`, `option`
- [x] Create `src/Fiber_Helpers.res`, move: `poll`
- [x] Create `src/Stream_Helpers.res`, move: `paginateEffect`, `grouped`, `runCollect`, `runHead`
- [x] Keep all other Effect files unchanged (Schedule, Stm, Layer, PubSub, Queue — pure bindings)
- [x] Update all consumer references

### Step 10: rescript-mcp-sdk — McpSdk_Helpers.res
- [x] Create `src/McpSdk_Helpers.res`
- [x] Move from `McpSdk.res`: typed handler wrappers, `textContent`/`toolResult`/`toolError` builders, `parseJsonBody`
- [x] Keep in `McpSdk.res`: all types, server/transport externals, raw `setRequestHandler`, `onData`/`onEnd` bindings
- [x] Update consumer references

### Step 11: Final verification
- [x] Run full monorepo build from root: `npm run build`
- [x] Run full test suite: `npm run test`
- [x] Verify no rescript compiler warnings

## Files Created (11 new files)

| Package | New File |
|---------|----------|
| rescript-aws-sdk | `src/S3_Helpers.res` |
| rescript-aws-sdk | `src/SNS_Helpers.res` |
| rescript-aws-sdk | `src/SQS_Helpers.res` |
| rescript-aws-sdk | `src/DynamoDb_Util_Helpers.res` |
| rescript-fast-csv | `src/FastCSV_Helpers.res` |
| rescript-moment | `src/MomentRe_Helpers.res` |
| rescript-pulumi-pulumi | `src/Output_Helpers.res` |
| rescript-effect | `src/Effect_Helpers.res` |
| rescript-effect | `src/Fiber_Helpers.res` |
| rescript-effect | `src/Stream_Helpers.res` |
| rescript-mcp-sdk | `src/McpSdk_Helpers.res` |

## Risks

- **Output_Helpers has the widest blast radius** — Output.flatMap/zip/unzip are used throughout the framework (~50 consumer sites)
- **Effect.tryPromise and Stream.runCollect** are the second most impactful (~35 and ~80 consumer sites respectively)
- **MomentRe_Helpers affects the UI repo** — rescript-moment is shared via file reference with reventless-ui. Consumer updates span two repos.
