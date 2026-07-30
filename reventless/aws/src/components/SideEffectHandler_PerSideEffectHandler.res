// The arm a side-effect-bearing Task reaches, via `Task_Builder_PerBucket`.
//
// It is `SideEffectHandler_Single` — the same shared "AllSideEffectHandlers" Lambda.
// Two earlier wirings both produced no Lambda at all:
//
//   - `ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(…)` builds
//     through `RuntimeEnvironment.make` = `CallbackFunction` = a serialized closure,
//     and the handler closes over Effect, which Pulumi's closure walker cannot
//     serialize. Construction threw and the function went missing.
//   - AWS's `EventCollectorRuntime_Builder_PerEventCollector` type-checks against the
//     same `forEventCollector` signature but dispatches on a `readModelInfos`
//     registry and bundles `ReadModelEntryPoint.mjs`. A side-effect handler is never
//     in that registry, so it took the builder's `None` arm, logged
//     "no bundled info registered", and created nothing — silently.
//
// Matching signatures are not matching behaviour. The registry a builder reads is
// the part that has to line up: side-effect handlers need `sideEffectInfos` and
// `SideEffectEntryPoint.mjs`, which is what `SideEffectHandler_Single` registers into.
//
// There is deliberately no per-handler Lambda behind this name. If per-handler
// memory/timeout tuning is wanted, add a real
// `SideEffectHandlerRuntime_Builder_PerSideEffectHandler` over the same registry and
// point this module at it.
include SideEffectHandler_Single.Make()
