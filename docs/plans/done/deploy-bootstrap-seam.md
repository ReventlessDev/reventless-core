# Plan: `DeployBootstrap` seam — extension point for generated deploy programs

**Status**: Implemented (2026-07-11). Phases 1–3 landed —
`ReventlessInfra.DeployBootstrap` seam, generator emission, and `@deprecated` on
the redundant `registerDcbConfig`.
**Nature**: small, additive framework seam + one generator emission. No-op by
default, so every existing hand-written or generated deploy program builds and
previews byte-identical until it opts in. Touches `reventless-infra` (new seam),
`reventless-spec/src/generator/Codegen.res` (emit the call), and optionally a
deprecation on `reventless-aws` `PluginRuntime_Builder.registerDcbConfig`.

## Motivation

`generate-plugin` emits a fixed deploy program (`renderMain` in
`reventless-spec/src/generator/Codegen.res`):

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Platform = ReventlessAws.Platform.Make()
module <Name> = Plugin.Make(Platform)
let default = Platform.deployPlugin(~plugin=module(<Name>))
```

There is **no extension point**. Any cross-cutting activation that must run at
deploy time — a runtime backend registering a config seam, an operational
extension that must be wired *before* `deployPlatform`/`deployPlugin` — can only
be added by hand-editing the generated file, which defeats regeneration (the
file carries a "do not edit" banner). The result downstream is that generated
programs get forked into hand-maintained copies that drift from the skeleton.

The framework already has the two ingredients for a clean fix:

- **A registry-seam precedent**: `ReventlessCore.Monitoring.use(module(Backend))`
  — extensions register into a module-level registry consulted lazily at each
  provisioning site. Nothing hand-edits the generated file.
- **An auto-registration precedent**: `registerPluginName(name)` is called
  automatically from `Plugin_Builder.res:1069` when a plugin builds, so the
  deploy path already populates deploy-time state without a line in `Main.res`.

This plan generalizes that into one named seam the generator can emit, so
deploy-time extension becomes *registration*, not *file editing*.

## Design

### The seam — `ReventlessInfra.DeployBootstrap`

New provider-neutral module in `reventless-infra` (home of the provider-neutral
adapter layer; consumed by every backend and by the generator's output):

```rescript
// Ordered phases at which bootstrap contributions run during a deploy program.
type phase =
  | PreDeploy   // before deployPlatform / deployPlugin — seam registration,
                // ordering-sensitive activations
  | PostDeploy  // after the platform/plugin graph is registered — exports,
                // cross-stack output emission

// Register a contribution. Contributions run in registration order within a
// phase. Safe to call at module-load time (import side effect) or explicitly.
let register: (~phase: phase=?, unit => unit) => unit

// Run all contributions registered for a phase. Emitted by generated deploy
// programs; idempotent per phase (running an already-run phase is a no-op).
let run: phase => unit
```

Semantics:
- **No-op by default.** Zero registrations ⇒ `run` does nothing ⇒ existing
  programs are unaffected.
- **Registration order** within a phase; if real ordering constraints emerge,
  add an optional `~priority` (defer until needed — YAGNI for now).
- Backend-agnostic: the seam holds `unit => unit` thunks; what a contribution
  does (register a `Monitoring` backend, wire a config, emit an export) is the
  contribution's concern, not the seam's.

### Generator emission — `Codegen.res` `renderMain`

Emit the phase calls around the existing body:

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
ReventlessInfra.DeployBootstrap.run(PreDeploy)

module Platform = ReventlessAws.Platform.Make()
module <Name> = Plugin.Make(Platform)
let default = Platform.deployPlugin(~plugin=module(<Name>))

ReventlessInfra.DeployBootstrap.run(PostDeploy)
```

- `renderMain` is AWS-mode only today; if a platform-mode deploy template exists
  or is added, it emits the same two calls around `deployPlatform`.
- The generated file gains two stable lines and no other change — programs with
  no registrations still preview byte-identical.

### Optional cleanup — deprecate manual `registerDcbConfig`

`reventless-aws` `PluginRuntime_Builder.registerDcbConfig(~pluginName, …)` sets
`dcbConfigRef.pluginName`, which is **already** set automatically by
`registerPluginName(name)` (`Plugin_Builder.res:1069`) when the plugin builds.
For the common case (pluginName only, no slice-path override) the manual call is
redundant. Options, cheap pre-1.0:
- Keep it only for the slice-path-override use; document that pluginName is
  auto-registered and the bare `~pluginName` call is unnecessary.
- Or deprecate the public function outright once no in-repo caller needs it.

This is independent of the seam and can land first.

## Phases

1. **Seam** — add `ReventlessInfra.DeployBootstrap` (`register`/`run`, `phase`).
   Unit tests: registration order, phase isolation, idempotent `run`, no-op when
   empty.
2. **Generator** — `renderMain` emits `run(PreDeploy)` / `run(PostDeploy)`.
   Regenerate the in-repo example deploy programs; `pulumi preview` on an example
   stack shows **0 resource diff** (the calls are no-ops with no registrations).
3. **(Optional) `registerDcbConfig` deprecation** — as above; independent.

## Acceptance

- `ReventlessInfra.DeployBootstrap` present, unit-tested, no-op when unused.
- `generate-plugin` output carries the two `run` calls; regenerated example
  programs `pulumi preview` byte-identical.
- Existing backends (`reventless-aws`, `reventless-local`) build unchanged.
- No provider types leak into the seam (holds `unit => unit` only).

## Out of scope

Per-phase ordering/priority beyond registration order; a general "deploy plugin"
lifecycle (this is a minimal pre/post activation seam, not a hook framework);
any specific contribution's implementation (those live in the packages that
register them, not here).

## Notes for downstream consumers

Consumers of generated deploy programs move deploy-time activations from
hand-edited lines to `DeployBootstrap.register(...)` calls in their own package
init, so regeneration no longer clobbers them. The seam names nothing about any
specific extension — it is generic registration, exactly as `Monitoring.use` is.
