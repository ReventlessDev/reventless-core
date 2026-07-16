# Plan: Configurable per-component runtime resources (memory & timeout)

## Problem

An application developer authoring a plugin controls only two surfaces: the
`@@reventless.spec` domain modules and the plugin's `plugin.json`. The
per-component wiring — `ordering/src/Plugin.res` in the online-shop-hybrid
example — is **generated** (`AUTO-GENERATED — do not edit`) from those two
inputs, and the individual component `make` calls are buried inside
`Platform.Plugin.make` / the platform's `deployPlugin` loop. There is **no
hand-written `.make(~memorySize=…)` seam** the developer can reach.

Runtime memory / timeout is therefore configurable today only where a component
builder happens to expose it directly:

| Component kind | Developer-facing `~memorySize` / `~timeout`? | Effective size |
| --- | --- | --- |
| SideEffectHandler | ✅ `~memorySize`/`~timeout` on `make` (default 2048) — `SideEffectHandler.res:26` | dev value or default |
| EventMapper | ✅ `~memorySize`/`~timeout` on `make` (default 2048) — `EventMapper.res:17` | dev value or default |
| Aggregate | ❌ `make` takes only `~api`/`~opts` — `Aggregate.res:92` | builder default (1024) |
| ReadModel / ReadModelStream | ❌ `make` takes only `~api`/`~apiRole`/`~allEventTopics` — `ReadModel.res:15` | builder default (1024) |
| StateChangeSlice / StateViewSlice / Automation / DCB / ExtensionPoint | ❌ none | builder default |
| Task | ❌ hardcoded `~memorySize=4096` — `Task_Builder.res:174` | fixed 4096 |

So the person who actually knows a given component is heavy — a read model that
rebuilds a large projection, a slice that batches imports — cannot express it.
A platform-level or operator-level per-*kind* default (e.g. "all read models get
512 Mi") cannot say "*this one* read model needs 4×".

**This is not platform-specific.** Memory/timeout are consumed by every runtime
adapter: AWS sets the Lambda `memorySize`/`timeout`, k8s sets the pod
`resources.requests`/`limits` and `terminationGracePeriodSeconds`, the in-memory
local runtime ignores both. The configuration surface and its threading belong
in **core / infra / spec**, not in any single platform adapter.

### There is already a precedent to copy

`heartbeatInterval` is a plugin-level runtime knob that flows without touching
the domain specs or the generated file by hand:

```
plugin.json  →  Config.res (read)  →  Codegen.res (emit)  →  generated Plugin.res
  "heartbeatInterval": 5              config.heartbeatInterval        ~heartbeatInterval=5
```

- `reventless-spec/src/generator/Config.res:62` reads the field.
- `reventless-spec/src/generator/Codegen.res:660` emits it into `Platform.Plugin.make(...)`.

Per-component memory/timeout should ride the **same rail**, keyed by component
name.

## Design principle

Runtime resource sizing is a **deployment/composition** concern, not a **domain**
concern. Keep the `@@reventless.spec` modules purely about domain truth
(schemas, tags, `decide`/`evolve`) so they stay portable across platforms, and
put the resource knob on the composition surface the developer already owns:
`plugin.json`. This also matches where the two existing knobs live
(SideEffectHandler / EventMapper expose them on the builder/composition layer,
never on a Spec).

Precedence is a **floor + override**: the platform/operator default sets the
floor per component kind; a `plugin.json` entry can only raise a specific
component above it. This is exactly the semantics the aggregate runtime builder
already implements — `Math.Int.max(spec.memorySize, memorySize)` in
`AggregateRuntime_Builder_Common.res:116` — so the override composes with any
platform default without conflict.

## Why the sizing is platform-agnostic (and what legitimately is not)

It is the **same Node handler code** running on Lambda, on a k8s pod, and in the
in-memory local runtime. Its working-set memory and the wall-clock it needs to
finish a unit of work are properties of that code, **not** of the environment it
lands in. So the per-component value must be declared **once**, portably, and
consumed identically everywhere. Duplicating it per platform is not just
redundant — it invites drift (tune AWS to 2 Gi, forget k8s, get an OOM in only
one environment). This is the whole reason the knob lives in core `plugin.json`
and there is **no per-platform sizing config**.

Two things are genuinely *not* portable, and the design deliberately keeps them
out of the per-component value — they belong to the environment/adapter, never to
the component:

1. **Defaults and floors are a deployment-environment concern, not a component
   concern.** A single-node dev/kind cluster wants everything floored small to
   fit; prod wants headroom. The *same* read model is "512 MiB" logically in
   both — what differs is where it's deployed. So the floor lives in the
   platform/stack layer (k8s `RuntimeMemory` + Pulumi stack config per
   environment), and the portable per-component value only ever *raises above*
   it. The residual variability here is really **per-environment** (dev vs prod),
   which merely happens to also be per-platform.

2. **The per-component value is a logical envelope; the adapter may apply a
   platform-specific translation.** The knob is decoupled memory (heap working
   set). Adapters map it to their own resource model:
   - **AWS Lambda** couples `memorySize` → vCPU → billing (≈1 full vCPU near
     ~1.8 Gi, priced per GB-second). A handler that needs CPU/speed but little
     heap may have its Lambda memory raised by the adapter purely to buy CPU —
     even though the logical envelope is small.
   - **k8s** decouples memory and CPU (`resources.memory` vs `resources.cpu`),
     and with `requests == limits` the number is a hard scheduling reservation.
   - **Timeout** is portable, but ceilings/derivations are not: Lambda hard-caps
     at 15 min; a pod runs arbitrarily long and k8s derives
     `terminationGracePeriodSeconds = timeout + drainMargin`.

   **Consequence to document loudly:** the number a developer writes in
   `plugin.json` is the *logical* envelope, not a literal cap. Do not assume
   `"memorySize": 512` means the Lambda is capped at 512 — the AWS adapter may
   have bumped it for CPU. The value is the floor of what the component needs,
   translated per platform, not the ceiling of what it gets.

If CPU ever needs to be tuned in its own right (relevant on k8s, coupled on
Lambda), it is a **new field on the same `runtime` record**, not a reason to
fork the mechanism per platform — the record is designed to grow.

## Developer surface — `plugin.json`

Extend the plugin config JSON with an optional `runtime` block, keyed by
component `name` (the same names that already appear in the generated plugin —
`Customers`, `Orders`, `PlaceOrder`, …). Anything omitted falls through to the
per-kind default.

```json
{
  "name": "Ordering",
  "heartbeatInterval": 5,
  "runtime": {
    "Customers":  { "memorySize": 2048 },
    "Orders":     { "memorySize": 1024, "timeout": 120 },
    "PlaceOrder": { "memorySize": 768 }
  }
}
```

`memorySize` is in MiB, `timeout` in seconds — both optional inside each entry.
An unknown component name is a **generation-time warning** (typo protection), not
a silent no-op.

## Threading (all in core / infra / spec)

The chain, front to back, with the insertion point at each layer:

1. **`reventless-spec/src/generator/Config.res`** — add
   `componentRuntime: dict<string, runtimeHints>` to the `config` record and
   parse the `runtime` object from `plugin.json` (mirror the existing
   `getIntField` helpers; each entry decodes optional `memorySize` / `timeout`).
   `runtimeHints = { memorySize: option<int>, timeout: option<int> }`.
2. **`reventless-spec/src/generator/Codegen.res`** — when emitting
   `Platform.Plugin.make(...)`, also emit
   `~componentRuntime=Dict.fromArray([("Customers", {memorySize: Some(2048), timeout: None}), …])`.
   Validate every key against the discovered component names; warn on a miss.
3. **`reventless-core/src/plugin/component/Plugin.res` (`Plugin.make`)** — add
   an optional `~componentRuntime: dict<string, runtimeHints>=?` parameter
   (alongside `~heartbeatInterval`, `~aggregates`, …). Thread it into the
   platform's `deployPlugin` loop so that, as each component module is realized,
   its `name` is looked up and the hints handed to that component's `make`.
4. **Component `make` signatures** — add an optional `~runtime: runtimeHints=?`
   to `Aggregate.make`, `ReadModel.make`/`ReadModelStream`, the slice components,
   `ExtensionPoint`, and the DCB command/view components. (This param is set by
   the platform deploy loop, **not** by the app developer — the developer's
   surface stays `plugin.json`.) The already-configurable SideEffectHandler /
   EventMapper fold their existing `~memorySize`/`~timeout` into this same
   `~runtime` record so there is one mechanism, not three.
5. **Runtime builders** — pass the resolved value into the existing
   `registerRuntimeSpec(~memorySize, ~timeout, …)`. The aggregate/read-model/DCB
   builders already size the pod/Lambda from `spec.memorySize` via
   `Math.Int.max`. Two builders currently take the size from an incoming param
   or a framework constant and must instead honor the setting:
   - Task — replace the hardcoded `~memorySize=4096` (`Task_Builder.res:174`)
     with a default the `plugin.json` value overrides.
   - ExtensionPoint — size from settings rather than the incoming `~memorySize`
     param.
6. **Platform adapters (consume the resolved value; may translate it)** —
   AWS → Lambda `memorySize`/`timeout` (and, per the memory→CPU coupling above,
   may raise memory to buy CPU); k8s → pod `requests==limits` +
   `terminationGracePeriodSeconds`; local → ignored. Each adapter's per-kind
   builder default remains the floor, and the value it receives is a *logical
   envelope* the adapter maps to its own resource model (see “Why the sizing is
   platform-agnostic”) — not a literal cap.

## Precedence & defaults

- **Floor**: the per-kind builder default (today `~memorySize=1024` for
  aggregate/read-model/DCB, `2048` for SideEffectHandler/EventMapper, `4096`
  Task). A platform/operator may lower or raise these per kind
  (platform-specific — see *Out of scope*).
- **Override**: a `plugin.json` `runtime.<Component>.memorySize` raises that one
  component via `Math.Int.max(floor, override)`. It never lowers below a spec's
  own declared minimum where one exists.
- **Timeout** follows the same override-if-present rule (no `max`; an explicit
  per-component timeout replaces the default, since a longer default is not
  inherently safer).

## Tests

- `Config.res` unit — `plugin.json` with a `runtime` block parses into
  `componentRuntime`; absent block → empty dict; unknown key surfaces a warning.
- `Codegen.res` golden — a fixture plugin with per-component overrides emits the
  expected `~componentRuntime=Dict.fromArray([...])` into the generated
  `Plugin.res`.
- Builder unit — `registerRuntimeSpec(~memorySize)` resolves
  `Math.Int.max(floor, override)`; an override below the floor is clamped up, an
  override above wins.
- One end-to-end golden per platform seam that the resolved value reaches the
  resource: AWS Lambda `memorySize`, k8s pod request/limit. Local asserts the
  hint is accepted and ignored.

## Worked example — online-shop-hybrid

`examples/online-shop-hybrid/ordering/src/plugin.json` today is
`{"name": "Ordering"}`. Adding the `runtime` block above regenerates
`ordering/src/Plugin.res` so the generated `Platform.Plugin.make(...)` carries
`~componentRuntime`; `Customers` deploys at 2 Gi while every other read model
keeps its default, with no edit to any `@@reventless.spec` module and no edit to
the generated file by hand. The same `plugin.json` drives AWS (Lambda memory) and
k8s (pod request/limit) identically.

## Out of scope (platform-specific — stays in the platform plans)

- **k8s per-pod-kind operator defaults + Pulumi stack wiring** (revised pod
  default numbers, `requests == limits` invariant, single-node kind-cluster
  sizing, retiring the manual `kubectl set resources` re-patch,
  `pulumi config set runtimeMemory:<kind>`): tracked in the reventless-sovereign
  k8s plan, which consumes this mechanism for the per-component override and
  keeps only the k8s-deployment-specific default/floor wiring.
- **AWS per-kind Lambda default overrides**: if/when needed, an AWS `Config`
  field feeds the same builder floors; no new core surface required.
