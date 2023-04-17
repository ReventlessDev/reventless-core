// functor to create specific Mapper for projections
module Spec = ReventlessSpec.Projection.Spec

module type StateTarget = {
  let name: string
  type state
  let state_decode: Js.Json.t => Belt.Result.t<state, Decco.decodeError> // TODO: is it possible to remove Decco here?
  let state_encode: state => Js.Json.t
}

module MakeGenericTargetFromStateTarget = (StateTarget: StateTarget): (
  Mapper.GenericTarget with type t = StateTarget.state
) => {
  let name = StateTarget.name
  type t = StateTarget.state
  let decode = StateTarget.state_decode
  let encode = StateTarget.state_encode
}

module Make = (
  DiscreteTarget: ReventlessSpec.Projection.Spec.Target,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := DiscreteTarget,
): (
  MapperNto1.Mapper
    with type targetState := DiscreteTarget.state
    and type action<'id, 'state> := Spec.action<string, DiscreteTarget.state>
) => {
  module GenericTarget = MakeGenericTargetFromStateTarget(DiscreteTarget)
  module GenericMappings = {
    module type Mapping = MapperNto1.Mapping
      with module Spec := Spec
      and type target := DiscreteTarget.state

    let mappings: array<module(Mapping)> = Mappings.mappings->Belt.Array.map((module(M)) => {
      module GenericMapping = {
        let sourceName = M.Source.name
        module Source = Mapper.MakeGenericSourceFromEventSource(M.Source)
        let map = MapperNto1.makeGenericMap(Source.decode, M.map)
      }
      module(GenericMapping: Mapping)
    })
  }
  include MapperNto1.Mapper(Spec, GenericTarget, GenericMappings)
}
