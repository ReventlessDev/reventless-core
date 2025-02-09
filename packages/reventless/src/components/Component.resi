type t<'component, 'outputs, 'operations>

let setOperations: (t<'component, 'outputs, 'operations>, Pulumi.Output.t<'operations>) => unit
let operations: t<'component, 'outputs, 'operations> => Pulumi.Output.t<'operations>

let extractOutputs: t<'component, 'outputs, 'operations> => 'outputs
let extractMultipleOutputs: array<t<'component, 'outputs, 'operations>> => array<'outputs>
let extractWrappedOutputs: Pulumi.Output.t<t<'component, 'outputs, 'operations>> => Pulumi.Output.t<
  'outputs,
>

let toPulumiResource: t<'component, 'outputs, 'operations> => Pulumi.Resource.t

type constructed
let setOutputs: ('component, 'outputs) => constructed

let make: (
  ~componentType: string,
  ~name: string,
  ~construct: 'construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => 'component

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => 'component
}
