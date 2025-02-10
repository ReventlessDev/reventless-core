type t<'component, 'outputs, 'operations>

@set
external setOperations: (
  t<'component, 'outputs, 'operations>,
  Pulumi.Output.t<'operations>,
) => unit = "operations"
@get
external operations: t<'component, 'outputs, 'operations> => Pulumi.Output.t<'operations> =
  "operations"

// in Component.js setOutputs(_), which is called in the constructor sets the output keys
@get
external getOutputKeys: t<'component, 'outputs, 'operations> => array<string> = "outputKeys"

type propValue
@val @scope("Object")
external objFromEntries: array<(string, propValue)> => 'b = "fromEntries"

type obj
external toObj: t<'component, 'outputs, 'operations> => obj = "%identity"
let unsafeGetProp: (obj, string) => propValue = %raw(`
  function(obj, prop) {
    return obj[prop]
  }
`)
let unsafeGetProp: (obj, string) => propValue = (obj, key) => unsafeGetProp(obj, key)

let extractOutputs = component =>
  component
  ->getOutputKeys
  ->Belt.Array.map(key => (key, unsafeGetProp(component->toObj, key)))
  ->objFromEntries

let extractWrappedOutputs = component =>
  component->Pulumi.Output.apply(component => component->extractOutputs)

let extractMultipleOutputs: array<t<'component, 'outputs, 'operations>> => array<
  'outputs,
> = components => components->Belt.Array.map(extractOutputs)

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
@send
external setOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => unit = "setOutputs"

let setOutputs = (self, outputs) => {
  self->setOutputs(outputs)
  self->registerOutputs(outputs)
}
