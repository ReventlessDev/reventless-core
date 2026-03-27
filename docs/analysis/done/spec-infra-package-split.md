# reventless-spec / reventless-infra Package Split Analysis

**Status:** Analysis complete — no implementation plan yet

**Created:** 2026-03-02

**Revised:** 2026-03-02 — package named `reventless-infra` / `ReventlessInfra`; versioning and
alternative IaC tool sections added

---

## Background

The question arose while moving `commandsHandler` from `reventless-core` to `reventless-spec`: if
`commandsHandler` is a framework-internal routing type that belongs in spec only because other spec
files reference it, what does that say about the broader contents of `reventless-spec`?

The conclusion of that conversation: many types in `reventless-spec` are not things users implement —
they are infrastructure plumbing forced into spec by the dependency-direction constraint (spec cannot
import core). This analysis examines whether introducing a third package between spec and core would
improve the architecture, and at what cost.

---

## Current Two-Layer Architecture

```
reventless-spec   (36 files, namespace: Reventless)
      ↑
reventless-core  (148 files, namespace: ReventlessCore)
      ↑
reventless-aws   (AWS adapters)
```

**Dependency rule:** each layer imports only from layers below it. Application plugin code
(`CatalogPlugin.res`) depends only on `reventless-spec`, which is the explicit design goal expressed
in `Platform.res`:

> "Lives in reventless-spec so application plugin assembly code can depend only on reventless-spec."

`reventless-spec` depends on: `sury`, `rescript-pulumi-pulumi`, `rescript-effect`.

---

## The Mixed-Bag Problem in reventless-spec

Of the 36 files in `reventless-spec`, a sharp distinction emerges between two categories:

### Category A — Behavioral Contracts (what users implement, ~10 files)

These are the types application developers write against in their domain code:

| File | What users implement |
|------|---------------------|
| `Aggregate.Spec` | `command`, `event`, `error` union types; `Id` module |
| `Behavior.T` | `init`, `apply`, `create`, `execute` — the state machine |
| `ReadModel.Spec` | projected state schema + GraphQL config |
| `StateChangeSlice.Spec` | `decide`, `reduce`, `initialDecisionModel` — DCB write-side |
| `StateViewSlice.Spec` | `project`, `initialState` — DCB read-side |
| `DcbEventLog.Spec` | shared DCB event union |
| `EventMapping.T` | event-to-command routing logic |
| `Projection.Mapping` | event-to-state projection logic |
| `ExtensionPointMapping.Spec` | extension point command/event/directive types |
| `ExtensionMapping.T` | extension implementation (mapIncomingEvent, mapOutgoingEvent) |
| `SideEffect.T` | event-triggered side effect handler |
| `Task.Spec` | background job specification |
| `Behavior.T` (via `Handler.T`) | commandHandler, eventsHandler signatures |

### Category B — Infrastructure Types (~26 files)

These are framework plumbing that users consume but never implement themselves:

**Deploy-time outputs** (Pulumi.Output-wrapped resource descriptors):
`Aggregate.outputs`, `ReadModel.outputs`, `CommandTopic.outputs`, `EventTopic.outputs`,
`EventLog.outputs`, `QueryDb.outputs`, `EventCollector.outputs`, `CommandGenerator.outputs`,
`EventMapper.outputs`, `Counter.outputs`, `Plugin.outputs`, `ExtensionPoint.outputs`,
`Extension.outputs`, `Task.outputs`, `Heartbeat.outputs`, `DcbEventLog.outputs`,
`StateChangeSlice.outputs`, `StateViewSlice.outputs`

**Runtime operations** (async function bundles injected at Lambda startup):
`Aggregate.operations`, `CommandTopic.publishJsons`, `CommandTopic.publishJsonsStream`,
`CommandTopic.topicItem`, `CommandTopic.commandsHandler`, `EventTopic.publishJson`,
`DcbEventLog.operations`, `StateChangeSlice.operations`, `Scheduler.operations`,
`QueryEngine.operations`

**Component wiring**:
`Component.t` (universal component wrapper), `Platform.T` (abstract factory),
`Aggregate.T`, `ReadModel.T`, `Plugin.T`, `ExtensionPoint.T`, `Extension.T`, `Task.T`,
`DcbEventLog.T`, `StateChangeSlice.T`, `StateViewSlice.T`

**Message envelopes and routing**:
`Message.event'`, `Message.command'`, `Message.commandJson`, `Message.meta`, `Message.context`,
`ExtensionPointMapping.T` (compiled mapping), `ExtensionPointMapping.abstractCommandAction`

**Infrastructure utilities**:
`Adapter.resource`, `Adapter.resolvedResource`, `ResourceNaming.operations`,
`Schedule.rate/schedule`, `DcbTag.*`, `Id.String/StringPure`

### Why They Are in Spec

Infrastructure types live in `reventless-spec` not because users implement them, but because
other spec files reference them. `Aggregate.outputs` must be in spec because `Plugin.outputs`
(also in spec) has `aggregates: Pulumi.Output.t<dict<Aggregate.outputs>>`. `Platform.T` must be
in spec because `CatalogPlugin.res` — which is allowed to import only spec — calls
`Platform.Aggregate.Make(...)`. The transitive pull drags the entire infrastructure surface into spec.

---

## Proposed Three-Layer Architecture

```
reventless-spec    (pure behavioral contracts only, namespace: Reventless)
      ↑ imports
reventless-infra   (new: infrastructure types, namespace: ReventlessInfra)
      ↑ imports
reventless-core    (builders, callbacks, adapters — unchanged role, namespace: ReventlessCore)
      ↑ imports
reventless-aws     (AWS-specific implementations — unchanged role)
```

Application plugin code imports `reventless-infra` instead of `reventless-spec`
(since `reventless-infra` re-exports everything from `reventless-spec`).

### Package: reventless-infra / ReventlessInfra

The name `reventless-infra` is chosen over alternatives (`reventless-types`, `reventless-contract`,
`reventless-protocol`, `reventless-binding`) because it communicates the actual content: the
infrastructure contract layer that sits between pure domain logic and provider implementations. The
`ReventlessInfra` namespace keeps the naming family consistent and distinguishes it unambiguously
from `Reventless` (domain) and `ReventlessCore` (framework) at the module level.

### What Stays in reventless-spec (Pure Domain)

- All behavioral contracts: `Aggregate.Spec`, `Behavior.T`, `ReadModel.Spec`, `StateChangeSlice.Spec`,
  `StateViewSlice.Spec`, `DcbEventLog.Spec`, `EventMapping.T`, `Projection.Mapping`, `SideEffect.T`,
  `Task.Spec`, `Handler.T`, `ExtensionPointMapping.Spec`, `ExtensionMapping.T`
- Primitive identity types: `Id.T` (module type only — `Id.String` implementations could move)
- No Pulumi.Output references, no operations records, no routing types

Dependencies: `sury` only. Pulumi and Effect dependencies drop out entirely.

### What Moves to reventless-infra

Everything in Category B above, plus:
- `Platform.T` and the concrete module type factories (`Aggregate.T`, `ReadModel.T`, etc.)
- `Message.*` envelope types
- `Plugin.T`, `Plugin.DcbSpec`, `Plugin.outputs`
- `Component.t`, `Adapter.resource`/`resolvedResource`
- `DcbTag.*`, `Schedule.*`, `ResourceNaming.operations`, `QueryEngine.operations`

Dependencies: `reventless-spec` + `rescript-pulumi-pulumi` + `rescript-effect`.

---

## Advantages

### 1. Spec becomes genuinely minimal
`reventless-spec` shrinks to ~10 files of pure domain contracts. A new contributor reading the
package sees only what users implement: state machines, projection logic, decision models. No Pulumi,
no Effect, no routing machinery.

### 2. Domain logic testable without Pulumi
Behavioral implementations (`Behavior.T`, `StateChangeSlice.Spec`) depend only on `reventless-spec`,
which loses its Pulumi dependency entirely. Unit-testing domain logic — especially `Behavior.execute`
and `StateChangeSlice.decide` — becomes possible in packages that do not install Pulumi. This is
meaningful for CI speed and for testing in non-Pulumi environments.

### 3. Clearer responsibility model
The layer's name and contents communicate intent:
- `reventless-spec` (`Reventless`): what your application domain looks like
- `reventless-infra` (`ReventlessInfra`): how the framework wires components together
- `reventless-core` (`ReventlessCore`): the framework implementation
- `reventless-aws`: the AWS provider

### 4. Easier third-party platform implementations
An alternative cloud provider implementing Reventless (Azure, GCP, local Docker) only needs
`reventless-infra` as a target interface — they do not have to reconcile the behavioral and
infrastructure halves of `reventless-spec` simultaneously.

---

## Versioning Opportunities

With three packages versioned independently, each layer can evolve on its own cadence without
forcing downstream updates when only an unrelated layer changes.

### reventless-spec — slow-moving, high-stability

`reventless-spec` contains the fundamental domain contracts: `Aggregate.Spec`, `Behavior.T`,
`StateChangeSlice.Spec`, and so on. These are the types that determine what user application code
compiles against. They should be:

- **Breaking-change averse.** Adding a required field to `Aggregate.Spec` or changing the signature
  of `Behavior.execute` breaks every application that implements those contracts. Major version bumps
  here are rare and high-impact.
- **Stable public API.** Since `reventless-spec` has no Pulumi or Effect dependency, it can be
  consumed by tooling, code generators, documentation systems, and test utilities that do not need
  a cloud SDK.
- **Independent of infrastructure churn.** When the framework adds a new resource type to
  `Aggregate.outputs` (e.g., a secondary index or a dead-letter queue), `reventless-spec` does not
  need to update. Behavioral contracts are unaffected by infrastructure evolution.

### reventless-infra — medium cadence, infrastructure-driven

`reventless-infra` changes when the shape of component wiring changes: new output fields, new
operations, changes to `Platform.T`. These are typically additive and non-breaking for existing
applications, but may require `reventless-core` and `reventless-aws` updates to provide the new
operations. Version bumps here are more frequent than in spec but less frequent than in core.

A key versioning property: since `reventless-infra` defines `Platform.T`, the abstract factory that
application plugins use, the version of `reventless-infra` in the app's `package.json` is the
contract governing which platform capabilities are available. Bumping `reventless-infra` in the
app signals "I now require a platform that implements the new capabilities", and any `Platform.T`
implementation (`reventless-aws`, a future `reventless-azure`) must be updated in lockstep.

### reventless-core — fast-moving, implementation-driven

`reventless-core` can iterate rapidly on builder logic, callback implementations, adapter
internals, and performance optimisations without affecting the behavioral or infrastructure
contracts. Most day-to-day framework development lives here. Bug fixes, streaming improvements,
retry logic changes — none of these require version bumps in `reventless-spec` or `reventless-infra`
unless they also change a public type.

### reventless-aws — provider-specific cadence

AWS resource changes (new DynamoDB features, Lambda configuration options, SQS FIFO improvements)
land in `reventless-aws` independently of the domain and infrastructure contract layers. An AWS
SDK major version update, for example, may require a `reventless-aws` major bump but leaves
`reventless-spec` and `reventless-infra` untouched.

### Practical consequence: slimmer update surface for application teams

Today, any change to `reventless-spec` — including adding a new output field to some component —
requires application teams to update their single spec dependency. With three layers, the same
change only bumps `reventless-infra`. Application code that only imports `reventless-spec` for
its domain contracts never needs updating when infrastructure wiring evolves. This is especially
valuable when domain models are mature and stable but the framework is still actively developed.

---

## Alternative IaC Tool Support (CDK, Terraform CDK)

### The dependency on Pulumi.Output.t

Today `reventless-infra` (and currently `reventless-spec`) is deeply coupled to Pulumi's
`Output.t<'a>` type. Every `*.outputs` record carries `Pulumi.Output.t<'a>` fields, `Platform.T`
passes `Pulumi.Output.t<Scheduler.operations>`, and `Component.t` is wired by
`Pulumi.Output.apply` chains. Supporting AWS CDK or Terraform CDK would require abstracting this
coupling away — or accepting a parallel infra package per tool.

### What Pulumi.Output.t does in the framework

`Pulumi.Output.t<'a>` is not merely a resource descriptor — it is a **lazy computation monad**
used throughout the framework for two distinct purposes:

1. **Deploy-time deferral**: resource properties (ARNs, queue URLs, table names) are unknown until
   Pulumi runs the deployment. `Output.t` holds a promise-like container that is only resolved
   during `pulumi up`.
2. **Deploy-to-runtime value passing**: the framework uses `Output.apply` to construct runtime
   operation bundles (e.g., the DynamoDB table name is captured into a closure that becomes
   `EventLog.operations.append`). This is the mechanism by which deploy-time resource values
   become available inside Lambda handlers.

Any alternative IaC tool must provide an equivalent mechanism for both purposes.

### How CDK handles the same problem

AWS CDK uses a **token system** (`cdk.Token`, `cdk.Lazy`) for deferred values. At synthesis time,
resource properties that are not yet known (e.g., a DynamoDB table ARN) are represented as
unresolved token strings. These resolve to actual values after CloudFormation deploys. For runtime
value passing (the Lambda body needing the table name), CDK uses environment variables set at
synthesis time.

This is structurally similar to Pulumi's `Output.t`, but:
- CDK synthesis is **synchronous** — there is no `Output.apply` returning `Output.t`. The synthesis
  pipeline runs in a single pass and produces a CloudFormation template.
- CDK's token abstraction does not compose the way Pulumi's `Output.flatMap` does. It is a string
  placeholder, not a typed monadic container.
- ReScript bindings for CDK would look completely different from `rescript-pulumi-pulumi`.

### Paths to CDK support

**Option A: Parallel infra packages**

```
reventless-spec       (shared domain contracts)
      ↑ imports
reventless-infra      (Pulumi-specific component types — current proposal)
reventless-infra-cdk  (CDK-specific component types — parallel)
      ↑ imports
reventless-core       (shared callback/operations logic, no IaC coupling)
reventless-core-cdk   (CDK-specific builders)
      ↑ imports
reventless-aws        (Pulumi + AWS providers)
reventless-aws-cdk    (CDK constructs)
```

Application plugin code targeting CDK would import `reventless-infra-cdk` instead of
`reventless-infra`. `Platform.T` in `reventless-infra-cdk` uses CDK Construct types instead of
Pulumi Output types. Behavioral contracts in `reventless-spec` are fully shared.

**Advantage**: No abstraction over `Output.t` required. Each infra package is idiomatic for its
IaC tool. The domain contracts are genuinely portable.

**Disadvantage**: Application plugin code (`CatalogPlugin.res`) is not portable between Pulumi and
CDK — the functor arguments reference tool-specific types through `Platform.T`. Switching IaC
tools requires rewriting the plugin assembly layer.

**Option B: Abstract Output.t in reventless-infra**

`reventless-infra` defines an abstract `module type OutputT` with `apply`, `flatMap`, `all`, and
`make` operations. `Platform.T` becomes parametric over this module:

```rescript
// reventless-infra
module type OutputT = {
  type t<'a>
  let apply: (t<'a>, 'a => 'b) => t<'b>
  let flatMap: (t<'a>, 'a => t<'b>) => t<'b>
  let make: 'a => t<'a>
}

module type Platform = {
  module Output: OutputT
  module Aggregate: { module Make: (...) => Aggregate.T with module Output = Output }
  // ...
}
```

Application plugin code becomes parametric over `Output`:

```rescript
module Make = (P: Platform.T) => {
  module CategoryAggregate = P.Aggregate.Make(Category, CategoryBehavior, ...)
  let category = CategoryAggregate.make(~api, ~opts)
  // category outputs use P.Output.t — portable across Pulumi and CDK
}
```

**Advantage**: Application plugin code is genuinely IaC-tool-agnostic. Switching from Pulumi to
CDK requires only replacing the `Platform.T` implementation at the composition root.

**Disadvantage**: Every `*.outputs` type becomes `Output.t<'a>` where `Output` is a module
parameter. The type signatures throughout `reventless-infra` become significantly more complex.
ReScript's module system handles this but it increases the cognitive overhead and the length of
type errors considerably. This is a large-scale redesign, not an incremental refactor.

### The runtime operations layer is already IaC-agnostic

An important observation: `reventless-infra`'s runtime operations types (`publishJsons`,
`readStream`, `append`, `Scheduler.operations`, `QueryEngine.operations`) do **not** mention
`Pulumi.Output.t`. They are plain function types. This means that at runtime (inside Lambda
handlers), the framework is already IaC-tool-agnostic — only the deploy-time wiring (the
`*.outputs` records and `Component.t`) depends on Pulumi.

Consequently, the callbacks and operations logic in `reventless-core` can be shared between a
Pulumi implementation and a CDK implementation without changes. The IaC coupling is entirely in
the builder layer (how resources are provisioned and wired) and the output types (how resource
references are packaged). This means Option A is more tractable than it appears: `reventless-core`'s
callback modules (`Aggregate_Callback`, `StateChangeSlice_Callback`, etc.) would be fully reused
by a CDK implementation.

### Realistic assessment

CDK support is **possible** under Option A with moderate effort, because the runtime layer is
already decoupled. The split into `reventless-spec` + `reventless-infra` is a prerequisite — without
it, domain contracts are entangled with Pulumi types and cannot be cleanly shared.

Option B (abstract `Output.t`) is architecturally complete but impractical as an incremental step.
It would be worth revisiting only if there is an active user base on both Pulumi and CDK that needs
a single application codebase to target both.

The recommended sequencing if CDK support becomes a goal:
1. Complete the `reventless-spec` / `reventless-infra` split (establishes the clean boundary)
2. Verify that `reventless-core`'s callback modules require no Pulumi imports (they should not)
3. Create `rescript-aws-cdk` bindings as a parallel to `rescript-pulumi-pulumi`
4. Create `reventless-infra-cdk` with CDK-idiomatic component output types
5. Create `reventless-aws-cdk` implementing CDK constructs for each component
6. The application plugin layer then only needs to swap the `Platform.T` implementation

---

## Consequences and Costs

### Breaking API change for application code
Application plugins currently import `Reventless.*` for both domain and infrastructure types. After
the split, they import `Reventless.*` for domain contracts and `ReventlessInfra.*` for infrastructure
types. This requires updating `package.json` (new dependency on `reventless-infra`) and import
paths wherever infrastructure types are referenced explicitly.

Mitigation: `reventless-infra` re-exports `reventless-spec` contents under the `Reventless`
namespace alias where needed, minimising source-code changes for the common case where apps only
interact with `Platform.T` and the resulting component types.

### Cross-package type identity
ReScript's module system relies on nominal package boundaries for type identity. Currently
`Reventless.CommandTopic.topicItem` is the same type everywhere. After the split, the split must
be clean: `topicItem` lives in exactly one package (spec, since it is referenced by
`ExtensionPointMapping.res`) and is re-exported consistently. No type may be defined independently
in two packages, or functor applications will fail at the boundary.

### Circular reference risk
Several spec files have bidirectional references today. `Aggregate.outputs` references
`CommandTopic.outputs`, and `Plugin.outputs` references both. If these land in the same
`reventless-infra` package, the existing internal references work unchanged. But the behavioral
contracts remaining in `reventless-spec` that are referenced by infrastructure types in
`reventless-infra` must be one-directional (infra depends on spec, not vice versa), which requires
careful placement of every boundary type.

### Increased coordination overhead
Three packages means three versioning decisions on every change that crosses layers, three entries
in `package.json`/`rescript.json` for consumers, and three publish steps. For a single-team project
at the current scale this adds friction without proportional benefit. See the Versioning section
above for the long-term upside that offsets this.

---

## Effort Estimate

| Work item | Estimate |
|-----------|----------|
| New package scaffolding (`reventless-infra`: rescript.json, package.json, namespace, workspace config) | 1–2 h |
| Move and re-reference ~26 infrastructure files from spec to infra | 1–2 days |
| Update `reventless-core` imports (148 files) | 0.5–1 day |
| Update `reventless-aws`, `reventless-in-memory`, `reventless-interop` | 0.5 day |
| Update all example projects and tests | 0.5 day |
| Resolve namespace/type-identity edge cases | 0.5–1 day |
| Documentation and changelog | 0.5 day |
| **Total** | **3–5 days** |

Risk: medium. The main risk is subtle type-identity failures at functor application sites that only
manifest at compile time with opaque error messages, requiring careful tracking of which package
owns each type.

---

## Alternative: Folder Reorganization Within reventless-spec

Rather than a new package, reorganize `reventless-spec` internally:

```
src/
  domain/          ← behavioral contracts (current Category A)
    Behavior.res
    Aggregate.res  (Spec module type only)
    ReadModel.res  (Spec module type only)
    StateChangeSlice.res  (Spec only)
    ...
  infrastructure/  ← outputs, operations, routing (current Category B)
    Aggregate.res  (outputs, operations, T module type)
    CommandTopic.res  (outputs, publishJsons, topicItem, commandsHandler)
    Plugin.res
    Platform.res
    ...
```

**Advantages over the three-package approach:**
- No package boundary → no namespace/type-identity risks
- No versioning coordination overhead
- No breaking API change (module paths change internally but the `Reventless` namespace is preserved)
- Achieves the documentary separation that motivated the split
- Effort: ~1 day (file moves + `rescript.json` source path updates)

**Disadvantages:**
- Pulumi and Effect dependencies remain in `reventless-spec` — domain logic still cannot be tested
  without them, and CDK support is not enabled
- Dependency enforcement is by convention only, not by package boundary — a `domain/` file can still
  accidentally import `infrastructure/` without the compiler catching it
- Versioning granularity is not improved

---

## Recommendation

**Do the folder reorganization now; revisit the package split when a concrete trigger arrives.**

The concrete pain points at current scale are documentation clarity and contributor orientation —
both solved by the folder split within `reventless-spec`. The primary technical benefits of a full
package split (testable domain logic without Pulumi, independent versioning, CDK support path) are
real but not currently blocking development.

The package split becomes compelling when any of the following arrive:
- **A second platform implementation** (CDK, Azure) is actively developed — the domain/infra split
  is a prerequisite for clean portability
- **The team grows** and clear ownership of domain contracts vs infrastructure types becomes
  organizationally valuable across teams
- **Independent versioning becomes necessary** — e.g., domain contracts are declared stable (v1.0)
  while infrastructure types continue evolving (pre-1.0)
- **Compilation times become a bottleneck** — removing Pulumi from the domain-only path helps

At that point the folder reorganization done now will have already established the logical boundaries
and identified every cross-cutting dependency, making the package split mechanical rather than
architectural.
