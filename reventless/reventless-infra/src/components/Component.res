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

// Side-channel storage for outputs and operations.
// Using WeakMaps keyed by the component instance prevents Pulumi from
// serializing internal data (sury schemas, Spec modules) as ComponentResource
// properties in `pulumi stack output`.
type weakMap
@new external _makeWeakMap: unit => weakMap = "WeakMap"
@send external _get: (weakMap, t<'c, 'o, 'p>) => 'v = "get"
@send external _set: (weakMap, t<'c, 'o, 'p>, 'v) => unit = "set"

let _outputsStore = _makeWeakMap()
let _operationsStore = _makeWeakMap()

/** Access the deploy-time outputs record for this component. */
let outputs = (self: t<'component, 'outputs, 'operations>): 'outputs =>
  _outputsStore->_get(self)

/**
Access the deploy-time outputs wrapped in an `Output.t` (resolved asynchronously).
Useful when you need to chain outputs into another `Output.apply`.
*/
let wrappedOutputs = component => component->Pulumi.Output.apply(component => component->outputs)

let setOperations = (
  self: t<'component, 'outputs, 'operations>,
  ops: Pulumi.Output.t<'operations>,
): unit => _operationsStore->_set(self, ops)

/**
Access the runtime operations for this component.

Returns an `Output.t` that resolves to the runtime operations record once the
underlying infrastructure values are known. Use `TestRunner.resolve` in tests.
*/
let operations = (self: t<'component, 'outputs, 'operations>): Pulumi.Output.t<'operations> =>
  _operationsStore->_get(self)

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

@send
external _registerOutputs: (t<'component, 'outputs, 'operations>, 'a) => constructed =
  "registerOutputs"

/** Register the component's outputs with Pulumi to mark it as constructed. */
let registerOutputs = (self, outputs) => self->_registerOutputs(outputs)

/**
Set the component's outputs and mark the component as constructed.

Outputs are stored in a WeakMap (not on the ComponentResource instance) to prevent
Pulumi from serializing internal data in `pulumi stack output`. Cross-stack data
is exported explicitly via `Pulumi.export`.
*/
let setOutputs = (self, outputs) => {
  _outputsStore->_set(self, outputs)
  self->_registerOutputs(JSON.Encode.object(Dict.make()))
}
