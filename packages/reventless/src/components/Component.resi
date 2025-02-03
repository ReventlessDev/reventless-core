//type t<'component, 'outputs> constraint 'outputs = 'a
// TODO: remove? type unknown;
type t<'component, 'outputs>

let extractOutputs: t<'component, 'outputs> => 'outputs
let extractMultipleOutputs: array<t<'component, 'outputs>> => array<'outputs>
let extractWrappedOutputs: Pulumi.Output.t<t<'component, 'outputs>> => Pulumi.Output.t<'outputs>

external toPulumiResource: t<'component, 'outputs> => Pulumi.Resource.t = "%identity"
// TODO: remove? external toUnknown: t('component, 'outputs) => t(unknown, 'outputs) = "%identity";
