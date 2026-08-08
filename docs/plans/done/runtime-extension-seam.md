# Plan: A runtime cold-start seam for out-of-tree extensions

**Status.** Done — 2026-08-08. Planned and implemented the same day; anchors verified against the
code as landed.

**Goal.** Let a package outside the framework run code **once per runtime cold start**, inside a
provisioned Lambda, so it can register the runtime callback hooks the framework already ships.

**Non-goal.** Any particular extension, and any new hook. This adds the missing registration
path for hooks that already exist.

---

## 1. The gap: hooks with no way in

The framework ships four runtime extension points and, before this, no way for an out-of-tree
package to register any of them in a deployed runtime:

| Hook | Registrar |
| --- | --- |
| Command interception | `CommandGenerator_Callback.registerCommandInterceptor` |
| Query interception | `QueryDb_Callback.registerQueryInterceptor` |
| Before publish | `EventPublish_Callback.registerBeforePublish` |
| After publish | `EventPublish_Callback.registerAfterPublish` |

Each is a module-level `ref`, consulted on the hot path, defaulting to passthrough. Each is
therefore useless unless something calls the registrar **in the same process** before the first
request. In a deployed runtime nothing could:

- the handler is a framework-owned `.mjs` entry shell, named by a hardcoded `~entryPointModule=`
  in the runtime builders — none of which registered any of the four;
- the only modules a shell imports are framework modules and the user's Spec/Behavior modules,
  loaded by path from `HANDLER_CONFIG`. Those paths point at the *domain* package, so an
  extension had nowhere to place even a side-effecting import;
- `entryPointModule` is a literal at each builder call site, so an extension could not substitute a
  shell of its own.

The result was that `registerCommandInterceptor` and its three siblings were, in practice,
reachable only from a host that builds its own Lambda. Everything the framework provisions —
aggregates, DCB command topics, automation slices, read models, event collectors, side effects,
tasks — was closed.

This is not hypothetical scaffolding: interception is what per-command authorisation, request
tracing, rate limiting and any form of request accounting are built from, and each of them would
otherwise have to be added to the framework itself.

---

## 2. The precedent, and why runtime is the missing half

The framework had solved this exact shape twice, both times at **deploy time**:

- `Monitoring` — `module type Backend`, `Noop` default, `use` registration, `notify` at each
  provisioning site.
- `EventLogProvisioning` — the same, fired as each event log is created.

Both let an out-of-tree package attach behaviour without the framework knowing what the behaviour
is. Neither had a runtime counterpart, so an extension could shape *what gets provisioned* but not
*what runs inside it*.

This applies the same pattern one phase later.

---

## 3. The seam as built

`reventless/core/src/adapter/RuntimeExtension/RuntimeExtension.res`:

```rescript
type coldStartHook = (
  ~runtimeKind: ComponentType.t,
  ~component: string,
  ~plugin: option<string>,
  ~platform: option<string>,
) => unit

module type Extension = {
  let moduleUrl: string
  let onColdStart: coldStartHook
}

let use: module(Extension) => unit
let reset: unit => unit
let isEmpty: unit => bool
let moduleUrls: unit => array<string>
let notifyColdStart: (~runtimeKind, ~component, ~plugin, ~platform) => unit
let notifyColdStartHooks: (~hooks: array<coldStartHook>, ~runtimeKind, ~component, ~plugin, ~platform) => unit
```

Design notes, and where the shipped shape differs from the sketch:

- **Fire once, before the first request.** The shells' cold-start section, not per invocation.
  Idempotence is the seam's responsibility, not each extension's.
- **Pass the runtime's identity, not its internals.** An extension registering a command
  interceptor needs to know which runtime it is inside; it does not need the storage ops or the
  spec. Keeping the payload to identity is what stops this becoming a second, informal handler
  API — and the hooks it exists to reach already carry their own per-request payloads
  (`commandInterceptor` gets `~componentName` / `~tag` / `~args` on every call).
- **`runtimeKind` is `ComponentType.t`, not a new variant.** Every AWS runtime builder already
  passes its `~componentKind` to `makeFromCodeAsset`, so the seam needs no third taxonomy beside
  `Monitoring.unitKind` and `ResourceAttribution.Role`, and no call site has to learn one.
- **No `Noop`.** With an ordered array the neutral default is the empty registry — which is also
  the state that bundles nothing and sets no env var. A registered do-nothing extension would
  still cost a package in every archive, so the seam does not offer one.
- **`moduleUrl` is part of the module type.** This is what makes the seam reachable in a deployed
  runtime, and it is the substantive half the sketch flagged: registering a first-class module
  only populates the deploy program's process, and the Lambda is a different one. One `use` call
  therefore feeds both arms — the in-process registry for local, and the module list for AWS.
- **Attribution from the same source the deploy-time seams use.** `plugin`/`platform` are read
  from `ResourceAttribution.current` at provisioning time and carried into the runtime as
  configuration, since a runtime has no ambient deploy context.
- **Synchronous.** An async cold-start hook would have to be awaited before the first request and
  would put extension latency on the cold path. An extension needing I/O can start it and not
  block.

### How registration actually reaches the runtime

The sketch expected a list in `HANDLER_CONFIG` threaded through every builder. Two existing choke
points made that unnecessary — every runtime builder already routes through both:

- `Util_Bundle.buildCodeArchive` bundles arbitrary npm packages into `node_modules/<pkg>` in the
  archive (it already did this for `effect`). It now also adds each registered extension's
  package, resolved through `getModuleSpecifier`'s package-root walk — an out-of-tree package the
  framework has no dependency on would not survive a framework-rooted `require.resolve`.
- `RuntimeEnvironment_Lambda.makeFromCodeAsset` already receives `~name` and `~componentKind`, so
  it writes the seam's config to a `RUNTIME_EXTENSIONS` env var. Separate from `HANDLER_CONFIG`
  deliberately: that variable is already close to the 5120-byte
  `UpdateFunctionConfiguration` limit (the sketch's open question 3).

So **no runtime-builder call site changed**. The seam is default-on in `buildCodeArchive`, which is
what makes a runtime builder added later carry it by construction — the same argument
`EventLogProvisioning` made for firing from the builders rather than from each storage adapter.
The seven support Lambdas outside `Runtime/` (Upload presign/claim, Geocoder, StateTopic,
EventLogSubscription, ComponentDefinitions, UIFragments) pass `~bundleRuntimeExtensions=false`:
they have no command, query or publish path, so they never fire the seam and must not carry
modules they will not import.

---

## 4. Which runtimes

All of the `Runtime/` entry points, plus `reventless-local`.

The twelve hand-written `.mjs` shells share `HandlerFactoryHelpers.mjs`, which now starts the load
+ fire at module load and exports it as `runtimeExtensionsReady`; each shell awaits that promise
as the first statement of its own cold-start init. Awaiting inside init — rather than relying on
module evaluation order — is what makes "before the first request" a fact for the shells that build
handlers lazily. The four ReScript entry points (`Heartbeat`, `PgChangeFeedRelay`, `PgMigration`,
`PluginExtensionPoint`) bind the same promise via `@module` and await it at the top of `handler`,
the convention those files already use for the shared logger.

The shell's `import()` is the seam's one untyped step; parsing and invocation live in
`RuntimeExtensionEntryPoint_Ops.res` so the call's arity is compiler-checked. ReScript labelled
arguments compile to positional ones, and a hand-written `.mjs` call pinned to an unchecked
signature is exactly the arity drift that cost a production incident on the DCB command path.

---

## 5. Open questions, resolved

1. **Naming** — `RuntimeExtension`. It says what the thing is without saying what the extension
   does, matching the neutrality of `Monitoring` and `EventLogProvisioning`.
2. **One extension or several** — several. No scarce resource here (unlike the event-log seam's
   reader budget), and tracing and accounting are independent concerns that should compose.
   Ordering rule: registration order, which is the deploy program's statement order.
3. **How attribution reaches the runtime** — its own `RUNTIME_EXTENSIONS` env var, not
   `HANDLER_CONFIG`. See §3.
4. **Failure policy** — log and continue. Each hook is isolated; a throw is logged at ERROR naming
   the extension index and the runtime, and the remaining extensions still run. Failing the
   runtime would turn a broken extension into an outage.
5. **Local and sovereign runtimes** — fired once at `Platform.makePlatform`, before anything is
   built, with `runtimeKind: Platform` and `component: "LocalPlatform"`. Stated in the code: off
   Lambda every component runs in one process, so there is one cold start, not one per runtime.
   Firing per hosted component would hand an extension N identities for a single process and
   re-run registrations that are module-level refs anyway.

---

## 6. Acceptance

| Criterion | Evidence |
| --- | --- |
| A package outside this repo can register an extension in a deploy program, and its code runs once per cold start in every provisioned runtime | `RuntimeExtension.use` → bundled by `buildCodeArchive`, named in `RUNTIME_EXTENSIONS`, imported and fired by every `Runtime/` entry point |
| From that hook it can call the four registrars, and they fire on subsequent requests | `RuntimeExtensionHookReachTest` (an interceptor registered inside `onColdStart` denies a later command); live local run — `PROBE interceptor saw Category.Add` after a GraphQL mutation |
| A deployment registering nothing runs byte-identical code and pays nothing | `isEmpty()` gates both bundling and the env var; no `RUNTIME_EXTENSIONS`, no extra package, unchanged `sourceCodeHash` |
| The hook fires for every runtime kind, not a subset | Default-on in `buildCodeArchive`; `makeFromCodeAsset` is the single env-var site every `Runtime/` builder routes through; all 16 entry points await the runner |
| An extension that throws at cold start does not take the runtime down, and the failure is visible | `RuntimeExtensionTest` / `RuntimeExtensionEntryPoint_OpsTest`; live local run brought the platform fully up after logging `extension 1 threw at cold start of Platform(LocalPlatform); skipped` |

**Verification run.** Full root build, zero warnings. Full suite green: 310 suites / 2794 tests
across 16 jest projects. Local arm verified live against `examples/online-shop-aggregates/platform-local`
with two probe extensions (one working, one throwing): `onColdStart` fired once as
`Platform(LocalPlatform)`, registered a command interceptor from inside the hook, and that
interceptor saw a subsequent `Catalog_Category_Add` mutation.

**Not verified on real AWS.** The deployed arm is covered by unit tests either side of the
dynamic `import()` and by the unchanged-when-empty guarantee, but no extension has yet been
deployed to a live stack. The first out-of-tree extension should confirm the archive carries its
package and the shell's import resolves under `/var/task/node_modules`.

---

## Appendix: code anchors (as landed, 2026-08-08)

| Fact | Anchor |
| --- | --- |
| The seam | `reventless/core/src/adapter/RuntimeExtension/RuntimeExtension.res` |
| Runtime hooks it makes reachable | `CommandGenerator_Callback.res:16`; `QueryDb_Callback.res:12`; `EventPublish_Callback.res:25,29` |
| Command interception is consulted on the hot path | `CommandGenerator_Callback.res:124-136` |
| Extension packages bundled into the archive | `Util_Bundle.addRuntimeExtensionPackages`, called from `buildCodeArchive` |
| Support Lambdas that opt out | `~bundleRuntimeExtensions=false` at the seven non-`Runtime/` sites |
| `RUNTIME_EXTENSIONS` env var written | `RuntimeEnvironment_Lambda.makeFromCodeAsset`, beside the ESM-loader invariants |
| Typed parse + fire (the arity-safe half) | `reventless/aws/src/adapter/Runtime/RuntimeExtensionEntryPoint_Ops.res` |
| Load + fire, shared by the twelve `.mjs` shells | `HandlerFactoryHelpers.mjs` — `runtimeExtensionsReady` |
| Local arm | `reventless/local/src/Platform.res` — `makePlatform`, before anything is built |
| Deploy-time precedents mirrored | `Monitoring.res:68-108`; `EventLogProvisioning.res:83-165` |
| User-facing documentation | `packages/doc/docs-infrastructure/callback-hooks-and-adapter-wrapping.md` § Registering Hooks in a Deployed Runtime |
