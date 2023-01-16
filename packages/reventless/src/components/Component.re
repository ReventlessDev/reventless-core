type t('component, 'outputs) = 'outputs constraint 'outputs = Js.t('a);
type unknown;

// in Component.js setOutputs(_), which is called in the constructor sets the output keys
[@get]
external getOutputKeys: t('component, 'outputs) => array(string) =
  "outputKeys";

type propValue;
[@val] [@scope "Object"]
external objFromEntries: array((string, propValue)) => Js.t('b) =
  "fromEntries";

type obj;
external toObj: t('component, 'outputs) => obj = "%identity";
let unsafeGetProp: (obj, string) => propValue = [%raw
  {|
  function(obj, prop) {
    return obj[prop]
  }
|}
];
let unsafeGetProp: (. obj, string) => propValue =
  (. obj, key) => unsafeGetProp(obj, key);

let extractOutputs: t('component, 'outputs) => 'outputs =
  component =>
    component
    ->getOutputKeys
    ->Belt.Array.map(key => (key, unsafeGetProp(. component->toObj, key)))
    ->objFromEntries;

let extractMultipleOutputs:
  array(t('component, 'outputs)) => array('outputs) =
  components => components->Belt.Array.map(extractOutputs);

external toPulumiResource: t('component, 'outputs) => Pulumi.Resource.t =
  "%identity";
external toUnknown: t('component, 'outputs) => t(unknown, 'outputs) =
  "%identity";

// TODO:
//  - adapt components make function to return this t('outputs)
//  - add a `getOutputs` function to each component
//  - use getOutputs in each parent's component to set only the child's outputs as the parent's outputs
