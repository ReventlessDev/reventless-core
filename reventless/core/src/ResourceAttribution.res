/***
The vocabulary a deployed resource is attributed with: which model element owns
it, in what role, at what level. Provider-agnostic on purpose — AWS renders these
as namespaced `reventless:` tags, Kubernetes as `reventless.io` labels. Defining
them once here is what keeps the two backends (and the monitoring registry) from
drifting into private spellings of the same fact.

The three facts are deliberately independent:

- `ComponentType.t` — the *modelling* kind (Aggregate, StateViewSlice, …): what
  the element IS in the domain model.
- `Role.t` — the *deployment piece* (EventLog, QueryDb, Runtime, …): what job
  this particular resource does for that element. One component owns several
  pieces, so kind alone can't identify a resource.
- `Scope.t` — the level the resource is attributed to: an individual component,
  a plugin's shared substrate, or platform substrate.

Note this is NOT the same axis as `Monitoring.unitKind`, which classifies an
execution unit by what its *failure* means (CommandHandler / Projection /
Reactor). A `Runtime` role can be any of those; both facts are worth carrying and
neither derives from the other.
*/

/** The level a resource is attributed to. */
module Scope = {
  type t =
    | /** owned by one model component */ Component
    | /** shared substrate within a plugin (DcbEventLog, plugin DLQ, …) */ Plugin
    | /** shared substrate across the platform (API, auth, hosting, …) */ Platform

  let toString = scope =>
    switch scope {
    | Component => "component"
    | Plugin => "plugin"
    | Platform => "platform"
    }
}

/**
The deployment piece a resource implements. `Other(string)` is the escape hatch
for support pieces and future roles (same pattern as `Monitoring.unitKind`).
*/
module Role = {
  type t =
    | CommandTopic
    | EventTopic
    | StateTopic
    | EventLog
    | DcbEventLog
    | EventLogSubscription
    | EventCollector
    | QueryDb
    | /** the execution unit that runs a component's handler */ Runtime
    | /** queue/topic receiving messages that exhausted processing */ DeadLetter
    | /** scheduled invocation (heartbeat, task scheduler) */ Scheduler
    | /** log storage and log-derived metrics */ Logs
    | /** execution identity and its policies */ Identity
    | /** the GraphQL API surface and its resolvers */ Api
    | /** identity provider / user pools */ Auth
    | /** static-site hosting, CDN, certificates, DNS */ Hosting
    | /** VPC and its network plumbing */ Network
    | /** transport wiring between a source and a runtime */ EventSourceMapping
    | /** bulk data movement (cloner, migrations) */ DataTransfer
    | Other(string)

  let toString = role =>
    switch role {
    | CommandTopic => "CommandTopic"
    | EventTopic => "EventTopic"
    | StateTopic => "StateTopic"
    | EventLog => "EventLog"
    | DcbEventLog => "DcbEventLog"
    | EventLogSubscription => "EventLogSubscription"
    | EventCollector => "EventCollector"
    | QueryDb => "QueryDb"
    | Runtime => "Runtime"
    | DeadLetter => "DeadLetter"
    | Scheduler => "Scheduler"
    | Logs => "Logs"
    | Identity => "Identity"
    | Api => "Api"
    | Auth => "Auth"
    | Hosting => "Hosting"
    | Network => "Network"
    | EventSourceMapping => "EventSourceMapping"
    | DataTransfer => "DataTransfer"
    | Other(name) => name
    }
}

/**
The model component a provisioned resource belongs to.

Piece builders (EventLog, QueryDb, CommandTopic, EventTopic, EventCollector) are
shared building blocks applied as functors by many different component kinds — a
QueryDb is instantiated by ReadModel, StateViewSlice, AutomationSlice, both
translation slices and Counter. The adapter that provisions the physical resource
sits at the bottom of that chain and would otherwise only know its own piece, so
`kind` would collapse onto `role` and the owning component would be unrecoverable.
The owning builder passes this record down instead.

`name` is the owner's spec name (the component stem, `Products`), not the
suffixed resource name (`ProductsQueryDb`).
*/
type owner = {kind: ComponentType.t, name: string}

/**
Ambient deploy-time context: which plugin (and platform) is currently being
constructed. Adapters that create resources sit far below the builder that knows
these names, and threading two strings through every adapter signature would be a
large, purely mechanical churn — so the plugin builder publishes them here for
the duration of its construct, exactly as it already does for
`Logger.currentPluginName`.

The `enter`/`restore` bracket covers what runs **synchronously** inside the
builder's construct, and everything built there genuinely belongs to that plugin.

It does not cover all of construct. Builders defer part of their work until every
handler has registered, and they defer it by waiting on outputs — so that work
runs from a `Pulumi.Output.apply` callback, after construct has returned and
`restore` has already emptied the context. A resource created there would be
attributed to nobody, and `None` is a *meaningful* value here: it means
platform-scope substrate. So the miss does not read as a gap, it reads as a
positive answer, and a consumer cannot tell the two apart.

Deferred work therefore carries its own attribution. Capture the context while it
is still published and reinstate it around the callback: `deferred` for a
callback registered during construct and invoked later, and
`ResourceAttribution_Deploytime.applyAttributed` / `flatMapAttributed` for a
builder's own apply. Both restore afterwards, so several plugins' deferred work
can run from one apply without leaking into each other.

Everything Pulumi-shaped lives in that separate module, so this one stays
importable from code that ends up in a Lambda bundle.

Outside any plugin construct both are `None` — the correct answer for
platform-scope substrate.
*/
type context = {platform: option<string>, plugin: option<string>}

let current: ref<context> = ref({platform: None, plugin: None})

/** Publish the plugin being constructed; returns the previous context to restore. */
let enter = (~platform: string, ~plugin: string) => {
  let previous = current.contents
  current := {platform: Some(platform), plugin: Some(plugin)}
  previous
}

/** Restore the context captured by `enter`. */
let restore = (previous: context) => current := previous

/** Re-enter a whole captured context — including an empty one, which `enter`
    cannot express since it takes two required strings. Returns the previous
    context, exactly as `enter` does. */
let enterCaptured = (captured: context) => {
  let previous = current.contents
  current := captured
  previous
}

/** Run `fn` under `captured`, then put the previous context back — including
    when `fn` throws, so a failing deferred callback cannot strand the context
    and mis-attribute everything built after it. */
let within = (captured: context, fn: unit => 'a): 'a => {
  let previous = enterCaptured(captured)
  try {
    let result = fn()
    restore(previous)
    result
  } catch {
  | e =>
    restore(previous)
    throw(e)
  }
}

/** Capture the context now and wrap a callback so it runs under that context
    whenever it is finally called. For work registered during construct but
    executed later from an apply — a builder's deferred `finish`, whose whole
    purpose is to run after every handler has registered.

    Wrap at **registration**, not at the call site: the registries these
    callbacks land in are module-level and shared by every plugin, so by the time
    they run there is no single context that would be right for all of them. */
let deferred = (fn: unit => 'a): (unit => 'a) => {
  let captured = current.contents
  () => within(captured, fn)
}
