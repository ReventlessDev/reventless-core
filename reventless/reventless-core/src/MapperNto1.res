type mapGeneric<'action> = JSON.t => 'action
type mapImpl<'msg, 'action> = 'msg => 'action

let makeGenericMap: (Mapper.decode<'msg>, mapImpl<'msg, 'action>) => mapGeneric<'action> = (
  decode,
  map,
) =>
  json =>
    switch json->decode {
    | msg => msg->map
    | exception err =>
      let jsonStr = json->JSON.stringify
      JsError.throwWithMessage(
        `Error: Couldn't decode source message: ${err
          ->JSON.stringifyAny
          ->Option.getOrThrow}, ${jsonStr}`,
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
  let map: (~sourceName: option<string>, JSON.t) => array<action<'id, 'state>>
}

module type Mapping = {
  module Spec: Spec // to be removed via destructive replace in functor call
  let sourceName: string
  type target

  let project: JSON.t => Spec.action<string, target>
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
    sourceNameOpt->Option.mapOr([], sourceName =>
      mappings->Array.filter((module(Mapping: Mappings.Mapping)) =>
        Mapping.sourceName == sourceName
      )
    )
  let map = (~sourceName, json) =>
    findMappings(
      sourceName,
      Mappings.mappings,
    )->Array.filterMap((module(Mapping: Mappings.Mapping)) =>
      try Some(json->Mapping.project) catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(`Mapping failed: ${errMsg}`)->Effect.runSync
        None
      }
    )
}
