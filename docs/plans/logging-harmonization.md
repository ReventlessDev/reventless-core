# Plan: Logging Harmonization

> **Analysis:** `docs/analysis/logging-harmonization.md`
> **Status:** Phases 1–3 complete. EffectLogger with `[comp]` prefix done. Phases 4 (AWS Util files) and 5 deferred.

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
- [ ] `CommandPublisher.res` — already uses `Effect.logInfo`; migrate to `EffectLogger.logInfo(~comp)` (deferred)
- [ ] `GraphQL_SchemaInspector.res` — move SDL dump calls to `log.debug` (deferred, in-memory dev tooling)
- [ ] `PluginConnectExtension_Builder.res` — move 6 cross-plugin wiring calls to `log.debug` (deferred)

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

- [ ] `Util_DynamoDb.res` — replace `Console.*` with `log.info`/`log.error` (deferred)
- [ ] `Util_DynamoDbStream.res` — replace `Console.*` (deferred)
- [ ] `Util_SNS.res` — replace `Console.*` (deferred)
- [ ] `Util_SNS_FIFO.res` — replace `Console.*` (deferred)
- [ ] `EventCollectorChannel_Helpers.res` — replace `Console.*` (deferred)
- [ ] `Adapter.res` — confirm debug line suppression (deferred)

## Phase 5 — Remove legacy code

- [ ] `OutputLogger.res` — referenced by `reventless-layer-builder` post-process; leave in place
- [ ] `Mapper1toN.res` — remove commented-out `Console.log2` (deferred)
