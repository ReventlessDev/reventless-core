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
Ambient deploy-time context: which plugin (and platform) is currently being
constructed. Adapters that create resources sit far below the builder that knows
these names, and threading two strings through every adapter signature would be a
large, purely mechanical churn — so the plugin builder publishes them here for
the duration of its construct, exactly as it already does for
`Logger.currentPluginName`.

Safe because deploy-time resource construction is synchronous (the framework
forbids creating resources inside `Pulumi.Output.apply`), so everything built
between `enter` and `restore` genuinely belongs to that plugin. Outside any
plugin construct both are `None` — which is the correct answer for
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
