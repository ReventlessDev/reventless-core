// functor to create specific Mapper for projections
module Spec = ReventlessSpec.Projection

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
  Target: ReventlessSpec.Projection.Target,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Target,
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
        module Source = Projection.Mapping.MakeGenericSource(M)
        let map = MapperNto1.makeGenericMap(Source.decode', M.map)
      }
      module(GenericMapping: Mapping)
    })
  }
  include MapperNto1.Mapper(Spec, GenericTarget, GenericMappings)
}
