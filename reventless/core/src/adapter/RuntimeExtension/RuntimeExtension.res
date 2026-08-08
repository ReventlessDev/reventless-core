/**
Runtime hook: every provisioned runtime announces its cold start, so an extension
can register the runtime callback hooks the framework already ships — before the
runtime handles its first request.

No-op by default. Zero behavioral change unless an extension registers one via
`use` before the platform/plugin build: nothing is bundled, no env var is set, and
no code runs.

`Monitoring` and `EventLogProvisioning` are the deploy-time half of this shape —
they let an extension attach behaviour to *what gets provisioned*. This is the
runtime half: *what runs inside it*. Without it,
`CommandGenerator_Callback.registerCommandInterceptor`,
`QueryDb_Callback.registerQueryInterceptor` and the two
`EventPublish_Callback` publish hooks are unreachable in a deployed runtime —
each is a module-level `ref` consulted on the hot path, so it is useless unless
something calls the registrar in the same process first, and the framework-owned
entry shells import only framework and domain modules. Per-command authorisation,
request tracing, rate limiting and request accounting are all built from those
hooks, and each one is otherwise a change to the framework itself.

What an extension does at cold start is deliberately NOT a framework concern.
This only exposes the choke point through which the framework says "a runtime of
this kind just started, here is who it is" and leaves the reaction to the
listener.

See `docs/plans/done/runtime-extension-seam.md`.
*/

/**
What every registered extension is handed at cold start. Kept to the runtime's
IDENTITY on purpose: an extension registering a command interceptor needs to know
which runtime it is inside, not that runtime's storage ops or specs. Widening this
to internals would make it a second, informal handler API — and the four hooks it
exists to reach already receive their own per-request payloads
(`commandInterceptor` gets `~componentName` / `~tag` / `~args` on every call).

`~runtimeKind` is the modelling kind of the component the runtime runs — the same
`ComponentType.t` every AWS runtime builder already passes to
`RuntimeEnvironment_Lambda.makeFromCodeAsset`, so there is no third taxonomy to
keep in step with `Monitoring.unitKind` and `ResourceAttribution.Role`.

`~component` is the runtime's STATIC logical name — the shared Lambda's name where
several components of one kind share a runtime (`AllAggregatesCmdHandler`), the
component's own name where it does not. It identifies the runtime, not a single
model element; use the per-request `~componentName` on the interception hooks to
tell hosted components apart.

`~plugin` / `~platform` are the owning plugin and platform, taken at provisioning
time from the ambient `ResourceAttribution` context (the same source `AWS_Tags`,
`Monitoring.notify` and `EventLogProvisioning.notify` use) and carried into the
runtime as configuration — the runtime has no ambient deploy context of its own.
Both are `None` for a runtime provisioned outside any plugin construct.
*/
type coldStartHook = (
  ~runtimeKind: ComponentType.t,
  ~component: string,
  ~plugin: option<string>,
  ~platform: option<string>,
) => unit

/**
A runtime extension, registered by an extension (a deploy program) before the
platform builds. `onColdStart` is called once per runtime process, before that
runtime handles its first request.

`moduleUrl` is the extension module's own `import.meta.url`. It is what makes the
seam reachable in a *deployed* runtime: registering a first-class module only
populates the deploy program's process, and the Lambda is a different one, so the
framework bundles the module's package into the code archive and names the module
in the runtime's config for the entry shell to import. Spec and behavior modules
are carried into runtimes the same way. The convention matches
`@@reventless.spec`'s injected `let moduleUrl`, so a ReScript extension can lift
it from there.

**Synchronous.** An async hook would have to be awaited before the first request
and would put extension latency on every cold path. An extension needing I/O can
start it here and not block on it.

**Fired once, in registration order.** Unlike `EventLogProvisioning` there is no
scarce resource here (no stream-reader budget), so several extensions compose —
tracing and accounting are independent concerns. They run in the order they were
registered; an extension that depends on another having run first is relying on
its host's statement order, which is the only ordering the framework can promise.

**A throwing extension does not take the runtime down.** Each hook is isolated:
the failure is logged at ERROR and the remaining extensions still run. Failing the
runtime instead would turn a broken extension into an outage, which is a worse
trade than a loud, skipped hook.
*/
module type Extension = {
  let moduleUrl: string
  let onColdStart: coldStartHook
}

let extensions: ref<array<module(Extension)>> = ref([])

/**
Register a runtime extension. Must run before the platform/plugin build in the
deploy program (plain statement order — the registry is read when each runtime's
code archive and config are built). Additive: call once per extension.

There is no `Noop` default to register. The neutral state is the empty registry,
which is also the state that bundles nothing and sets no env var; a registered
do-nothing extension would still cost a package in every runtime's archive.
*/
let use = (e: module(Extension)) => extensions := extensions.contents->Array.concat([e])

/**
Drop every registration. Test-support only — deploy programs never call this.
*/
let reset = () => extensions := []

/** True when no extension is registered — the default. Deploy-time backends use
    this to skip bundling and config emission entirely, so a deployment that
    registers nothing produces a byte-identical archive. */
let isEmpty = () => extensions.contents->Array.length == 0

/**
The `import.meta.url` of every registered extension, in registration order. Read
by the provider's code-archive builder to bundle each extension's package and to
name the modules a deployed runtime imports at cold start.
*/
let moduleUrls = (): array<string> =>
  extensions.contents->Array.map(e => {
    module E = unpack(e)
    E.moduleUrl
  })

let log = Logger.fromEnv()

/**
Run one hook, isolated. A throwing extension is logged at ERROR and skipped; the
caller keeps going. See the failure-policy note on `Extension`.
*/
let runHook = (
  hook: coldStartHook,
  ~index: int,
  ~runtimeKind: ComponentType.t,
  ~component: string,
  ~plugin: option<string>,
  ~platform: option<string>,
) =>
  try hook(~runtimeKind, ~component, ~plugin, ~platform) catch {
  | exn =>
    let message =
      exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")
    log.error(
      ~comp="RuntimeExtension",
      `extension ${index->Int.toString} threw at cold start of ${runtimeKind->ComponentType.toString}(${component}); skipped: ${message}`,
    )
  }

/**
Fire the given cold-start hooks, in order, each isolated from the others. Used by
runtimes that resolve their extensions themselves — a deployed entry point loads
its extension modules dynamically, so it holds hooks rather than first-class
modules.
*/
let notifyColdStartHooks = (
  ~hooks: array<coldStartHook>,
  ~runtimeKind: ComponentType.t,
  ~component: string,
  ~plugin: option<string>,
  ~platform: option<string>,
) =>
  hooks->Array.forEachWithIndex((hook, index) =>
    hook->runHook(~index, ~runtimeKind, ~component, ~plugin, ~platform)
  )

/**
Announce a runtime's cold start to every extension registered in THIS process.
Called by in-process runtimes (the local platform), where the deploy program and
the runtime share a process so the registry is already populated. A deployed
runtime cannot use this — its registry is empty until it imports the extension
modules named in its config — and calls `notifyColdStartHooks` instead. No-op
until an extension registers.
*/
let notifyColdStart = (
  ~runtimeKind: ComponentType.t,
  ~component: string,
  ~plugin: option<string>,
  ~platform: option<string>,
) =>
  notifyColdStartHooks(
    ~hooks=extensions.contents->Array.map(e => {
      module E = unpack(e)
      E.onColdStart
    }),
    ~runtimeKind,
    ~component,
    ~plugin,
    ~platform,
  )
