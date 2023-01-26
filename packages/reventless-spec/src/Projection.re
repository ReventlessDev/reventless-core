module Spec = Projection_Spec;

module type Mapping = {
  module Source: Projection_Spec.Source;
  module Target: Projection_Spec.Target; // NOTE: to be destructive substituted
  let map:
    Message.event'(string, Source.event) => Spec.action(string, Target.state);
};

module type Mappings = {
  module Target: Projection_Spec.Target; // to be removed via destructive replace in functor call
  module type Mapping = Mapping with module Target := Target;
  let mappings: array(module Mapping);
};
