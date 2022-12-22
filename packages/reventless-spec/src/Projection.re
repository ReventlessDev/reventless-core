module Spec = Projection_Spec;

module type Mapping = {
  module Source: Projection_Spec.Source;
  type target; // NOTE: to be destructive substituted
  let map: (Source.event, Message.context) => Spec.action(string, target);
};

module type Mappings = {
  module Target: Projection_Spec.Target; // to be removed via destructive replace in functor call
  module type Mapping = Mapping with type target := Target.state;
  let mappings: array(module Mapping);
};
