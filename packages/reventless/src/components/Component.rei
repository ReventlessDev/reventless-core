type t('component, 'outputs) constraint 'outputs = Js.t('a);
// TODO: remove? type unknown;

let extractOutputs: t('component, 'outputs) => 'outputs;
let extractMultipleOutputs: array(t('component, 'outputs)) => array('outputs);

external toPulumiResource: t('component, 'outputs) => Pulumi.Resource.t = "%identity";
// TODO: remove? external toUnknown: t('component, 'outputs) => t(unknown, 'outputs) = "%identity";
