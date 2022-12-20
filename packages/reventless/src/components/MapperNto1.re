open ReventlessSpec.Mapper;
open ReventlessSpec.MapperNto1;

module Mapping =
       (
         Spec: Spec,
         //  Source: Spec.Source,
         //  Target: Spec.Target,
         Impl:
           MappingImpl with
             module Spec := Spec /*and  type source = Spec.ToGenericSource(Source).t and  type target = Spec.ToGenericTarget(Target).t*/,
       )
       : (Mapping with module Spec := Spec and module Target := Impl.Target) => {
  let sourceName = Impl.Source.name;
  module Target = Impl.Target;

  let map = json => {
    switch (
      json->ReventlessSpec.Message.context_decode,
      json->Impl.Source.decode,
    ) {
    | (Ok(context), Ok(source)) => source->Impl.map(context)
    | _ =>
      Js.Exn.raiseError("Couldn't decode source:" ++ json->Js.Json.stringify)
    };
  };
};

module type Mapper = {
  module Spec: Spec; // to be removed via destructive replace in functor call
  module Target: GenericTarget;
  let map:
    (~sourceName: option(string), Js.Json.t) =>
    array(Spec.action(string, Target.t));
};

module Mapper =
       (
         Spec: Spec,
         Target: GenericTarget,
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
