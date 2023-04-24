//type t<'component, 'outputs> constraint 'outputs = 'a
// TODO: remove? type unknown;

let extractOutputs: ReventlessSpec.Component.t<'component, 'outputs> => 'outputs
let extractMultipleOutputs: array<ReventlessSpec.Component.t<'component, 'outputs>> => array<'outputs>

external toPulumiResource: ReventlessSpec.Component.t<'component, 'outputs> => Pulumi.Resource.t = "%identity"
// TODO: remove? external toUnknown: t('component, 'outputs) => t(unknown, 'outputs) = "%identity";
