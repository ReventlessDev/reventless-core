# Plan: Logging Harmonization

> **Analysis:** `docs/analysis/logging-harmonization.md`
> **Status:** All phases complete. OutputLogger intentionally kept (layer-builder dependency). Mapper1toN is fully commented-out dead code — no action needed.

---

## Phase 1 — Logger module + format (prerequisite)

- [x] Create `reventless-core/src/util/Logger.res` with `makeLogger` / `fromEnv` / `silent` implementation (deploy-time + non-Effect runtime)
- [x] Update `LogFormat.res` with `fmtCmd`, `fmtEventJson`, `fmtState`, `fmtCmds`, `fmtExn` helpers
- [x] Create `EffectLogger.res` — compact Effect logger that strips `timestamp=/level=/fiber=` metadata from log output
  - Self-installing: mutates `Logger.defaultLogger.log` at module import time (affects all `Effect.runPromise`/`runSync` globally)
  - Imported by `Platform.res` (in-memory) at startup
  - Log level routing: Error → `console.error`, Warning → `console.warn`, Info/Debug → `console.log`
  - Structured `logInfo`/`logWarn`/`logError`/`logDebug` helpers with `~comp` parameter → `[comp] message` prefix

## Phase 2 — Reduce chatty logs

- [x] `AggregateRuntime_Builder_Common.res` — 3 `*****` Console.log calls → `log.debug`; dispatch logs → `EffectLogger.logDebug(~comp="AggregateRuntime(...)")`
- [x] `EventCollectorRuntime_Builder_Single.res` — `*****` registration → `log.debug`; `validateParent` → `log.debug`; dispatch logs → `EffectLogger.logDebug(~comp="EventCollectorRuntime(...)")`
- [x] `Projection.res` — `logAction` (Console.log2) → `log.debug`; `handleActions` Console.log → `log.info` summary; Console.warn* → `log.warn`
- [x] `CommandPublisher.res` — migrated from `Effect.logInfo/logError` to `EffectLogger.logDebug/logError(~comp="CommandPublisher")`
- [x] `GraphQL_SchemaInspector.res` — 12 `Console.log` calls in `printFragment` migrated to `log.debug(~comp="GraphQL")`
- [x] `PluginConnectExtension_Builder.res` — migrated to `Logger.fromEnv()` with `log.debug/info/error(~comp="Admin")`

## Phase 3 — Add missing logs + `[comp]` prefix migration

- [x] `StateViewSlice_Callback.res` — `EffectLogger.logInfo(~comp)` for raw/decoded/actions counts; `EffectLogger.logWarn(~comp)` for skipped events
- [x] `Heartbeat_Callback.res` — `log.info(~comp="Heartbeat")` on publication with `id=` and `timeout=`
- [x] `Aggregate_Callback.res` — full migration to `EffectLogger.logInfo/logWarn/logError(~comp=\`Aggregate(${Spec.name})\`)` with concise key=value format
- [x] `ReadModel_Callback.res` — `EffectLogger.logInfo(~comp=\`ReadModel(${ReadModelSpec.name})\`)` with `actions=` count
- [x] `Plugin_Helpers.res` — improved error messages with `log.error(~comp="Plugin_Helpers")`; "plugin not found" includes known plugin list
- [x] `AggregateRuntime_Builder_Common.res` no-handler path — `EffectLogger.logWarn(~comp)` with `available=[...]`
- [x] `CommandGenerator_Callback.res` — `EffectLogger.logInfo(~comp=\`CommandGenerator(${serviceName})\`)`
- [x] `CommandTopic_Callback.res` — `EffectLogger.logInfo/logError(~comp="CommandTopic")`
- [x] `CommandTopic_Operations.res` — `EffectLogger.logInfo/logError(~comp="CommandTopic")`
- [x] `EventTopic_Operations.res` — `EffectLogger.logInfo/logError(~comp="EventTopic")`

## Phase 4 — Standardize remaining Console calls (AWS adapters)

- [x] `Util_DynamoDb.res` — migrated to `log.info(~comp="DynamoDb")` via `ReventlessCore.Logger.fromEnv()`
- [x] `Util_DynamoDbStream.res` — migrated to `log.info(~comp="DynamoDbStream")` via `ReventlessCore.Logger.fromEnv()`
- [x] `Util_SNS.res` — migrated to `log.error(~comp="SNS")` via `ReventlessCore.Logger.fromEnv()`
- [x] `Util_SNS_FIFO.res` — no Console calls found; clean
- [x] `EventCollectorChannel_Helpers.res` — migrated 5 `Console.log2/log3` to `log.debug(~comp="EventCollector")`, removed commented-out code
- [x] `Adapter_Helpers.res` — confirmed no Console calls; clean

## Phase 5 — Remove legacy code

- [x] `OutputLogger.res` — intentionally kept with `Console.log2`/`Console.error`; referenced by `reventless-layer-builder` post-process
- [x] `Mapper1toN.res` — entire file is commented-out dead code; no action needed
