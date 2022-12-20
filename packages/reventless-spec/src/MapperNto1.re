open Mapper;

module type Spec = {
  module type Source;
  module type Target;
  // module ToGenericSource: (Source) => GenericSource;
  // module ToGenericTarget: (Target) => GenericTarget;

  type action('id, 'a);
};

module type MappingImpl = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  module Source: GenericSource;
  module Target: GenericTarget;

  let map: (Source.t, Message.context) => Spec.action(string, Target.t);
};

module type Mapping = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  let sourceName: string;
  module Target: Mapper.GenericTarget; // to be removed via destructive replace in functor call

  let map: Js.Json.t => Spec.action(string, Target.t);
};

module type Mappings = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  module Target: Mapper.GenericTarget; // to be removed via destructive replace in functor call
  module type Mapping =
    Mapping with module Spec := Spec and module Target := Target;
  let mappings: array(module Mapping);
};
