/**
A Reventless component — a typed wrapper around a Pulumi `ComponentResource`.

Type parameters:
- `'component` — the concrete component module type (e.g. `Aggregate.T`)
- `'outputs` — the deploy-time outputs record (infrastructure references)
- `'operations` — the runtime operations record (async functions for Lambda handlers)

Components are created at deploy time by a `Make` functor and carry two payloads:
- `outputs` — immediately available infrastructure references (queue ARNs, table names…)
- `operations` — an `Output.t`-wrapped set of async functions injected at runtime
*/
type t<'component, 'outputs, 'operations>

@set
external setOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => unit = "outputs"

/** Access the deploy-time outputs record for this component. */
@get
external outputs: t<'component, 'outputs, 'operations> => 'outputs = "outputs"

/**
Access the deploy-time outputs wrapped in an `Output.t` (resolved asynchronously).
Useful when you need to chain outputs into another `Output.apply`.
*/
let wrappedOutputs = component => component->Pulumi.Output.apply(component => component->outputs)

@set
external setOperations: (
  t<'component, 'outputs, 'operations>,
  Pulumi.Output.t<'operations>,
) => unit = "operations"

/**
Access the runtime operations for this component.

Returns an `Output.t` that resolves to the runtime operations record once the
underlying infrastructure values are known. Use `TestRunner.resolve` in tests.
*/
@get
external operations: t<'component, 'outputs, 'operations> => Pulumi.Output.t<'operations> =
  "operations"

/** Cast to a plain Pulumi resource (e.g. to pass to `~opts` as a parent). */
external toPulumiResource: t<'component, 'outputs, 'operations> => Pulumi.Resource.t = "%identity"
external fromPulumiResource: Pulumi.Resource.t => t<'component, 'outputs, 'operations> = "%identity"

type constructed

/**
Create a new Reventless component backed by a Pulumi `ComponentResource`.

- `componentType` — Pulumi type token (e.g. `"reventless:index:Aggregate"`)
- `name` — unique Pulumi resource name
- `construct` — a callback that builds child resources; called by the Pulumi runtime
- `opts` — optional Pulumi resource options (parent, provider, etc.)
*/
@module("./Component.mjs") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: 'construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => t<'component, 'outputs, 'operations> = "default"

/** Register the component's outputs with Pulumi so they appear in the stack state. */
@send
external registerOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => constructed =
  "registerOutputs"

/**
Set the component's `outputs` property and register them with Pulumi in one call.
Use this instead of calling `setOutputs` and `registerOutputs` separately.
*/
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs)
  self->registerOutputs(outputs)
}
