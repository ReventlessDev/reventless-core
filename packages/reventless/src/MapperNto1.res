type mapGeneric<'action> = Js.Json.t => 'action
type mapImpl<'msg, 'action> = 'msg => 'action

let makeGenericMap: (Mapper.decode<'msg>, mapImpl<'msg, 'action>) => mapGeneric<'action> = (
  decode,
  map,
  json,
) =>
  switch json->decode {
  | Ok(msg) => msg->map
  | Error(err) =>
    let jsonStr = json->Js.Json.stringify
    Js.Exn.raiseError(
      `Error: Couldn't decode source message: ${err
        ->Js.Json.stringifyAny
        ->Belt.Option.getExn}, ${jsonStr}`,
    )
  }

module type Spec = {
  module type Source
  module type Target

  type action<'id, 'a>
}

module type Mapper = {
  type targetState
  type action<'id, 'state>
  let map: (~sourceName: option<string>, Js.Json.t) => array<action<'id, 'state>>
}

module type Mapping = {
  module Spec: Spec // to be removed via destructive replace in functor call
  let sourceName: string
  type target

  let map: Js.Json.t => Spec.action<string, target>
}

module type Mappings = {
  module Spec: Spec // to be removed via destructive replace in functor call
  module Target: Mapper.GenericTarget // to be removed via destructive replace in functor call
  module type Mapping = Mapping with module Spec := Spec and type target := Target.t
  let mappings: array<module(Mapping)>
}

module Mapper = (
  Spec: Spec,
  Target: Mapper.GenericTarget,
  Mappings: Mappings with module Spec := Spec and module Target := Target,
): (
  Mapper
    with type targetState := Target.t
    and type action<'id, 'state> := Spec.action<string, Target.t>
) => {
  let findMappings = (sourceNameOpt, mappings) =>
    sourceNameOpt->Belt.Option.mapWithDefault([], sourceName =>
      mappings->Belt.Array.keep((module(Mapping: Mappings.Mapping)) =>
        Mapping.sourceName == sourceName
      )
    )
  let map = (~sourceName, json) =>
    findMappings(
      sourceName,
      Mappings.mappings,
    )->Belt.Array.keepMap((module(Mapping: Mappings.Mapping)) =>
      try Some(json->Mapping.map) catch {
      | exn =>
        Js.log2("Mapping failed:", exn->Js.Exn.asJsExn->Belt.Option.map(Js.Exn.message))
        None
      }
    )
}
