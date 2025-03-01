type t<'component, 'outputs, 'operations>

type constructed
let registerOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => constructed
let setOutputs: (t<'component, 'outputs, 'operations>, 'outputs) => constructed
let outputs: t<'component, 'outputs, 'operations> => 'outputs
let wrappedOutputs: Pulumi.Output.t<t<'component, 'outputs, 'operations>> => Pulumi.Output.t<
  'outputs,
>
let setOperations: (t<'component, 'outputs, 'operations>, Pulumi.Output.t<'operations>) => unit
let operations: t<'component, 'outputs, 'operations> => Pulumi.Output.t<'operations>

let toPulumiResource: t<'component, 'outputs, 'operations> => Pulumi.Resource.t

let make: (
  ~componentType: string,
  ~name: string,
  ~construct: 'construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => t<'component, 'outputs, 'operations>
