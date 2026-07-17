type mapGeneric<'action> = JSON.t => 'action
type mapImpl<'msg, 'action> = 'msg => 'action

let makeGenericMap: (Mapper.decode<'msg>, mapImpl<'msg, 'action>) => mapGeneric<'action> = (
  decode,
  map,
) => json => json->decode->map

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
  /**
  Variant TAGs declared by this mapping's source-event schema. The mapping
  pipeline pre-filters incoming JSON by TAG and only invokes `project` for
  variants in this list — sibling variants on the same source log are
  silently skipped without any decode attempt.
  */
  let acceptedTags: array<string>
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

  let variantTagOfEnvelope = json =>
    json
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("event"))
    ->Option.map(Message.variantNameOfJson)
    ->Option.getOr("unknown")

  let map = (~sourceName, json) => {
    let tag = variantTagOfEnvelope(json)
    findMappings(
      sourceName,
      Mappings.mappings,
    )->Array.filterMap((module(Mapping: Mappings.Mapping)) =>
      // Skip silently when the variant is not in this mapping's source schema —
      // the mapping has explicitly opted out of these variants.
      Mapping.acceptedTags->Array.includes(tag) ? Some(json->Mapping.project) : None
    )
  }
}
