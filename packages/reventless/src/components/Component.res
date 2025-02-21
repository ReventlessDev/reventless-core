type t<'component, 'outputs, 'operations>

@set
external setOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => unit = "outputs"
@get
external outputs: t<'component, 'outputs, 'operations> => 'outputs = "outputs"
let wrappedOutputs = component => component->Pulumi.Output.apply(component => component->outputs)

@set
external setOperations: (
  t<'component, 'outputs, 'operations>,
  Pulumi.Output.t<'operations>,
) => unit = "operations"
@get
external operations: t<'component, 'outputs, 'operations> => Pulumi.Output.t<'operations> =
  "operations"

external toPulumiResource: t<'component, 'outputs, 'operations> => Pulumi.Resource.t = "%identity"

type constructed

@module("./Component") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: 'construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => t<'component, 'outputs, 'operations> = "default"

@send
external registerOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => constructed =
  "registerOutputs"

let setOutputs = (self, outputs) => {
  self->setOutputs(outputs)
  self->registerOutputs(outputs)
}
