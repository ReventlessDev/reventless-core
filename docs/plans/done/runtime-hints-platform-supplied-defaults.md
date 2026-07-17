# Plan: Platform-supplied `RuntimeHints` defaults for EP + Task pods

## Problem

`RuntimeHints.resolveMemory`/`resolveTimeout` take a `~default` that is the
per-kind **floor** (`Math.Int.max(default, override)` — an override can only
raise it). Today that default is **hardcoded in core's per-component builders**:

- `core/src/components/ExtensionPoint/ExtensionPoint_Builder.res:95-96`
  ```rescript
  ~memorySize=runtime->ReventlessInfra.RuntimeHints.resolveMemory(~default=1024),
  ~timeout=runtime->ReventlessInfra.RuntimeHints.resolveTimeout(~default=30),
  ```
- `core/src/components/Task/Task_Builder.res:55-56`
  ```rescript
  let memorySize = ReventlessInfra.RuntimeHints.resolveMemory(runtime, ~default=4096)
  let timeout = ReventlessInfra.RuntimeHints.resolveTimeout(runtime, ~default=600)
  ```

Core resolves the value and hands the runtime builder a number, so a platform's
runtime builder **cannot lower** an EP/task pod below core's 1024/4096 — it only
ever sees `max(1024, override)`. This blocks the k8s productionisation work: the
k8s Platform can size its *shared* aggregate/read-model/DCB pods (they read a
platform `settings.memorySize`), but **extension-point and task pods are
per-component pods sized straight from core's resolved value**, so they stay
pinned at 1024/4096 MiB — over-provisioned for thin Node handlers on a modest
cluster. (See the k8s side: reventless-sovereign
`docs/plans/k8s-runtime-and-distribution-build.md`, "(B) DEFERRED — EP/task
cannot be lowered here".)

The default is a **deployment/environment** fact (how big a pod this platform
wants), not a domain fact — it belongs to the platform, not a core constant.

## Fix — the platform supplies the EP/task floor

Let each platform provide the per-kind default that core feeds into
`resolveMemory`/`resolveTimeout`, instead of the hardcoded `1024`/`4096` /
`30`/`600`. Override semantics are unchanged: a `plugin.json`
`runtime.<Component>` value still raises the pod above the platform floor via the
existing `Math.Int.max`.

**Recommended shape — a `Defaults` source on the core builder functors (smallest
blast radius).** `ExtensionPoint_Builder.Make` and `Task_Builder.Make` already
take the platform's runtime builder as a functor argument; give them the floor
the same way, as a tiny module value the platform binds at functor application:

```rescript
// core/src/components/ExtensionPoint/ExtensionPoint_Builder.res
module Make = (
  ExtensionPointRuntimeBuilder: ExtensionPointRuntime_Builder.T,
  Defaults: RuntimeDefaults.T,     // ← NEW: { let memorySize: int; let timeout: int }
  ...
) => {
  ...
  ~memorySize=runtime->RuntimeHints.resolveMemory(~default=Defaults.memorySize),
  ~timeout=runtime->RuntimeHints.resolveTimeout(~default=Defaults.timeout),
}
```

`RuntimeDefaults.T` is a one-line shared module type in reventless-infra:

```rescript
// infra/src/types/RuntimeDefaults.res
module type T = {
  let memorySize: int   // MiB floor for this pod kind on this platform
  let timeout: int      // seconds
}
```

Each platform binds it at the seam where it already applies the core functor:

- **reventless-aws** (`Platform.res`, the `ExtensionPoint`/`Task` factories):
  bind `{ let memorySize = 1024; let timeout = 30 }` (EP) and
  `{ 4096; 600 }` (task) — **preserves today's behavior exactly.**
- **reventless-local**: bind the in-memory equivalents (memory is ignored by the
  local runtime, so any sensible constant; keep current timeouts).
- **reventless-k8s** (downstream, in reventless-sovereign — see follow-up): bind
  from its operator-configurable `RuntimeMemory` (EP `extensionPoint`, task
  `task`), so EP/task **join the existing per-pod-kind knob** (default EP 384,
  task 1024) and drop below core's old floor.

Because the k8s Platform functor (`MakeWithConfig(Config)`) already has
`Config.runtimeMemory` in scope at application time, the k8s binding can be
Pulumi-configurable (`pulumi config set --path runtimeMemory.extensionPoint 384`)
with no extra plumbing — the same `RuntimeMemory` mechanism the shared pods use.

### Alternative considered (not recommended)

Add `let defaultMemorySize: unit => int` / `defaultTimeout` to
`ExtensionPointRuntime_Builder.T` and `TaskRuntime_Builder.T`. Rejected: those
`.T`s are sealed by **many** implementers (every AWS aggregate builder variant
implements `forCommandTopic`, plus local), so the change ripples far wider than
the two builders that actually own the default. The functor-arg shape touches
only the two core builders + one binding per platform.

## Touch points

- **infra**: new `RuntimeDefaults.res` (module type `T`, two `let`s). ~5 lines.
- **core**: `ExtensionPoint_Builder.res` + `Task_Builder.res` — add the `Defaults`
  functor arg; replace the four hardcoded literals with `Defaults.memorySize` /
  `Defaults.timeout`.
- **reventless-aws**: `Platform.res` `ExtensionPoint` + `Task` factory call sites
  — pass the 1024/30 and 4096/600 modules (behavior-preserving).
- **reventless-local**: the corresponding factory call sites.
- **Downstream follow-up (reventless-sovereign, NOT this plan)**: the k8s Platform
  binds `Defaults` from `RuntimeMemory`; add `extensionPoint?`/`task?` fields to
  `RuntimeMemory.t` + defaults (384 / 1024). Unblocks the k8s plan's deferred item.

## Scope note

Aggregate / read-model / event-collector builders also pass a hardcoded
`~default=1024` to `resolveMemory`, but on k8s those are **shared pods** sized by
the platform's `settings.memorySize` (already lowerable), so they are not blocked
and are out of scope here. If uniformity is wanted later, the same `Defaults`
arg extends to them — but adding it now would be churn without a consumer.

## Tests

- **infra**: `RuntimeDefaults` needs no test (a bare module type).
- **core**: extend the existing EP + task builder tests to assert the resolved
  `~memorySize`/`~timeout` track the **injected** `Defaults` (not a literal) —
  e.g. a builder wired with `{ memorySize: 256 }` and no per-component override
  sizes the pod at 256; with an override of 512 it sizes at
  `max(256, 512) = 512`.
- **aws**: a golden that the EP/task Lambda still requests 1024/4096 (regression
  guard on the behavior-preserving binding).

## Status — DONE (2026-07-17)

Implemented in reventless-core; all four packages build with zero warnings.

- **infra**: `reventless/infra/src/types/RuntimeDefaults.res` — module type `T`
  (`let memorySize: int`, `let timeout: int`), accessible as
  `ReventlessInfra.RuntimeDefaults`.
- **core**: `ExtensionPoint_Builder.res` + `Task_Builder.res` gained a trailing
  `Defaults: ReventlessInfra.RuntimeDefaults.T` functor arg; the four hardcoded
  literals now read `Defaults.memorySize` / `Defaults.timeout`. The admin
  `PluginExtensionPoint_Builder.res` (which wraps `ExtensionPoint_Builder.Make`)
  threads `Defaults` through too.
- **reventless-aws**: `components/ExtensionPoint_Builder.res` binds
  `{ memorySize = 1024; timeout = 30 }`; `components/Task_Builder_PerBucket.res`
  binds `{ 4096; 600 }`; `plugin/stack/Plugin_ExtensionPoint_Builder.res` reuses
  the EP `Defaults`. Behavior-preserving.
- **reventless-local**: `components/ExtensionPoint_Builder.res` (1024/30) +
  `components/Task_Builder.res` (4096/600) — memory ignored by the in-memory
  runtime; timeouts mirror AWS.
- **Tests**: existing `RuntimeHintsTest` (resolve semantics) and local
  EP/Task integration tests still green; new
  `reventless/aws/tests/ComponentRuntimeDefaultsTest.res` guards the four
  platform floor values (4 tests passing).

Downstream follow-up (reventless-sovereign k8s `Defaults` bound from
`RuntimeMemory`) remains out of scope, as planned.
