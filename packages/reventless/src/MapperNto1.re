type mapGeneric('action) = Js.Json.t => 'action;
type mapImpl('msg, 'action) =
  ('msg, ReventlessSpec.Message.context) => 'action;

let makeGenericMap:
  (Mapper.decode('msg), mapImpl('msg, 'action)) => mapGeneric('action) =
  (msgDecode, map, json) => {
    let jsonStr = json->Js.Json.stringify;
    switch (json->ReventlessSpec.Message.context_decode, json->msgDecode) {
    | (Ok(context), Ok(source)) => source->map(context)
    | (Error(err), Ok(_)) =>
      Js.Exn.raiseError({j|Couldn't decode context: $err, $jsonStr|j})
    | (Ok(_), Error(err)) =>
      Js.Exn.raiseError({j|Couldn't decode message: $err, $jsonStr|j})
    | (Error(errContext), Error(errMsg)) =>
      Js.Exn.raiseError(
        {j|Couldn't decode context & message: $errContext, $errMsg, $jsonStr|j},
      )
    };
  };

module type Spec = {
  module type Source;
  module type Target;

  type action('id, 'a);
};

module type Mapper = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  module Target: Mapper.GenericTarget;
  let map:
    (~sourceName: option(string), Js.Json.t) =>
    array(Spec.action(string, Target.t));
};

module type Mapping = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  let sourceName: string;
  type target;

  let map: Js.Json.t => Spec.action(string, target);
};

module type Mappings = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  module Target: Mapper.GenericTarget; // to be removed via destructive replace in functor call
  module type Mapping = Mapping with module Spec := Spec and type target := Target.t /* and type target := Target.t*/;
  let mappings: array(module Mapping);
};

module Mapper =
       (
         Spec: Spec,
         Target: Mapper.GenericTarget,
         Mappings:
           Mappings with module Spec := Spec and module Target := Target,
       )
       : (Mapper with module Spec := Spec and module Target := Target) => {
  let findMappings = (sourceNameOpt, mappings) =>
    sourceNameOpt->Belt.Option.mapWithDefault([||], sourceName =>
      mappings->Belt.Array.keep((module Mapping: Mappings.Mapping) =>
        Mapping.sourceName == sourceName
      )
    );
  let map = (~sourceName, json) =>
    findMappings(sourceName, Mappings.mappings)
    ->Belt.Array.keepMap((module Mapping: Mappings.Mapping) =>
        try (Some(json->Mapping.map)) {
        | exn =>
          Js.log2(
            "Mapping failed:",
            exn->Js.Exn.asJsExn->Belt.Option.map(Js.Exn.message),
          );
          None;
        }
      );
};
