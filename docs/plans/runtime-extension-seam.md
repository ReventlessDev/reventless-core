# Plan: A runtime cold-start seam for out-of-tree extensions

**Status.** Planned — 2026-08-08. Grounded against current runtime code; anchors in the appendix.

**Goal.** Let a package outside the framework run code **once per runtime cold start**, inside a
provisioned Lambda, so it can register the runtime callback hooks the framework already ships.

**Non-goal.** Any particular extension, and any new hook. This adds the missing registration
path for hooks that already exist.

---

## 1. The gap: hooks with no way in

The framework ships four runtime extension points and no way for an out-of-tree package to
register any of them in a deployed runtime:

| Hook | Registrar |
| --- | --- |
| Command interception | `CommandGenerator_Callback.registerCommandInterceptor` |
| Query interception | `QueryDb_Callback.registerQueryInterceptor` |
| Before publish | `EventPublish_Callback.registerBeforePublish` |
| After publish | `EventPublish_Callback.registerAfterPublish` |

Each is a module-level `ref`, consulted on the hot path, defaulting to passthrough. Each is
therefore useless unless something calls the registrar **in the same process** before the first
request. In a deployed runtime nothing can:

- the handler is a framework-owned `.mjs` entry shell, named by a hardcoded `~entryPointModule=`
  in the runtime builders — **14 shells, none of which registers any of the four**;
- the only modules a shell imports are framework modules and the user's Spec/Behavior modules,
  loaded by path from `HANDLER_CONFIG`. Those paths point at the *domain* package, so an
  extension has nowhere to place even a side-effecting import;
- `entryPointModule` is a literal at each builder call site, so an extension cannot substitute a
  shell of its own.

The result is that `registerCommandInterceptor` and its three siblings are, in practice,
reachable only from a host that builds its own Lambda. Everything the framework provisions —
aggregates, DCB command topics, automation slices, read models, event collectors, side effects,
tasks — is closed.

This is not hypothetical scaffolding: interception is what per-command authorisation, request
tracing, rate limiting and any form of request accounting are built from, and today each of them
would have to be added to the framework itself.

---

## 2. The precedent, and why runtime is the missing half

The framework has solved this exact shape twice, both times at **deploy time**:

- `Monitoring` — `module type Backend`, `Noop` default, `use` registration, `notify` at each
  provisioning site.
- `EventLogProvisioning` — the same, fired as each event log is created.

Both let an out-of-tree package attach behaviour without the framework knowing what the behaviour
is. Neither has a runtime counterpart, so an extension can shape *what gets provisioned* but not
*what runs inside it*.

This plan applies the same pattern one phase later.

---

## 3. The seam

```rescript
module type Extension = {
  /** Called once per cold start, before the first request is handled. */
  let onColdStart: (
    ~runtimeKind: runtimeKind,   // Aggregate | DcbCommandTopic | ReadModel | …
    ~component: string,          // the component this runtime serves
    ~plugin: option<string>,
    ~platform: option<string>,
  ) => unit
}

module Noop: Extension
let use: module(Extension) => unit
let notifyColdStart: (~runtimeKind, ~component, ~plugin, ~platform) => unit
```

Design notes:

- **Fire once, before the first request.** The shells already have a cold-start section; this
  belongs there, not per invocation. Idempotence should be the seam's responsibility, not each
  extension's.
- **Pass the runtime's identity, not its internals.** An extension registering a command
  interceptor needs to know which component it is inside; it does not need the storage ops or the
  spec. Keeping the payload to identity is what stops this becoming a second, informal handler
  API.
- **`Noop` by default**, so a deployment registering nothing behaves identically and pays nothing.
- **Attribution from the same source the deploy-time seams use**, so `plugin`/`platform` mean the
  same thing at runtime as they do at provisioning. At runtime this is configuration rather than
  ambient context, so it has to be threaded through `HANDLER_CONFIG` — see open question 3.
- **Synchronous.** An async cold-start hook would have to be awaited before the first request and
  would put extension latency on the cold path. If an extension needs I/O it can start it and not
  block.

### The registration problem this does not solve by itself

A seam is only reachable if the extension's module is **in the shell's import graph**, and the
shell imports only framework and domain modules. So the seam needs a way for a deployment to name
its extension modules — most naturally a list in `HANDLER_CONFIG`, populated at provisioning from
whatever the deploy program registered, which the shell imports alongside the Spec/Behavior
modules it already loads dynamically.

That is the substantive part of this work. The `module type` above is the easy half.

---

## 4. Which shells

All of them, or the seam has the same partial-coverage problem the event-log seam was written to
avoid. There are 14 entry shells; they share a cold-start structure, and several already share
`HandlerFactoryHelpers.mjs`, which is the natural place for a single `runExtensions(config)` both
the shells and any future one call.

Firing uniformly and letting extensions ignore runtimes they do not care about is simpler than a
partial contract — the same conclusion the event-log seam reached about in-memory storage.

---

## 5. Open questions

1. **Naming.** `RuntimeExtension`? `RuntimeBootstrap`? It should not imply *what* the extension
   does — the neutrality of `Monitoring` and `EventLogProvisioning` is the model.
2. **One extension or several.** Unlike the event-log seam, there is no scarce resource here
   (no reader budget), so an array is defensible and probably right: tracing and accounting are
   independent concerns that should compose. If so, ordering needs a stated rule.
3. **How attribution reaches the runtime.** `ResourceAttribution.current` is a deploy-time
   construct. Runtime needs the same names via `HANDLER_CONFIG`, which is already close to a
   documented size limit — check before adding fields.
4. **Failure policy.** An extension that throws at cold start: fail the runtime, or log and
   continue? Failing turns a broken extension into an outage; continuing turns it into silent
   loss. Recommend logging and continuing, with the failure surfaced loudly.
5. **Local and sovereign runtimes.** The in-process backends have no cold start in the same
   sense. Either fire once at host startup or state that the seam is per-runtime-process and
   means something slightly different off Lambda.

---

## 6. Acceptance

- A package outside this repo can register an extension in a deploy program, and its code runs
  once per cold start in every provisioned runtime.
- From that hook it can call `registerCommandInterceptor`, `registerQueryInterceptor` and the
  publish hooks, and they fire on the subsequent requests.
- A deployment registering nothing runs byte-identical code and pays nothing.
- The hook fires for every runtime kind, not a subset.
- An extension that throws at cold start does not take the runtime down, and the failure is
  visible.

---

## Appendix: code anchors (verified 2026-08-08)

| Fact | Anchor |
| --- | --- |
| Runtime hooks that cannot be registered | `CommandGenerator_Callback.res:16`; `QueryDb_Callback.res:12`; `EventPublish_Callback.res:25,29` |
| Command interception is consulted on the hot path | `CommandGenerator_Callback.res:124-136` |
| Entry shells are framework-owned; 14 of them | `reventless/aws/src/adapter/Runtime/*.mjs` |
| None registers any runtime hook | grep over those shells returns nothing |
| Shell entry point is hardcoded per builder | `~entryPointModule=` at each runtime builder call site |
| Shells import only framework + user Spec/Behavior by path | `DcbCommandTopicEntryPoint.mjs` — `buildHandlersForConfig`, `loadModule` |
| Shared cold-start helper already exists | `reventless/aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs` |
| Deploy-time precedents to mirror | `Monitoring.res:68-107`; `EventLogProvisioning.res` |
