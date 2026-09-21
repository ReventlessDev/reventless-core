// functor to create specific Mapper for projections
module Spec = Reventless.Projection

module type StateTarget = {
  let name: string
  @schema
  type state
}

module MakeGenericTargetFromStateTarget = (StateTarget: StateTarget): (
  Mapper.GenericTarget with type t = StateTarget.state
) => {
  let name = StateTarget.name
  type t = StateTarget.state
  let decode = json => json->Message.decode(StateTarget.stateSchema)
  let encode = value => value->Message.encode(StateTarget.stateSchema)
}

module Make = (
  Target: Reventless.Projection.Target,
  Mappings: Reventless.Projection.Mappings with module Target := Target,
): (
  MapperNto1.Mapper
    with type targetState := Target.state
    and type action<'id, 'state> := Spec.action<string, Target.state>
) => {
  module GenericTarget = MakeGenericTargetFromStateTarget(Target)
  module GenericMappings = {
    module type Mapping = MapperNto1.Mapping
      with module Spec := Spec
      and type target := Target.state

    let mappings: array<module(Mapping)> = Mappings.mappings->Array.map((module(M)) => {
      module GenericMapping = {
        let sourceName = M.sourceName
        let acceptedTags = Reventless.DcbTag.extractAllVariantNames(M.sourceEventSchema)
        // The storage edge: the envelope and the table carry strings, the
        // projection typed ids — the same strings, decoded and encoded here.
        let decode = json => json->Message.decodeEvent'(M.SourceId.schema, M.sourceEventSchema)
        let project = MapperNto1.makeGenericMap(decode, msg =>
          msg
          ->M.project
          ->Reventless.Projection.mapActionId(~to_=M.targetIdToString, ~from=M.targetIdFromString)
        )
      }
      module(GenericMapping: Mapping)
    })
  }
  include MapperNto1.Mapper(Spec, GenericTarget, GenericMappings)
}
