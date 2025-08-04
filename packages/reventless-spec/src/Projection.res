module Spec = Projection_Spec

module type Mapping = {
  //module Source: Projection_Spec.Source
  //module Target: Projection_Spec.Target // NOTE: to be destructive substituted
  module SourceId: Id.T
  @schema
  type sourceEvent
  @schema
  type targetState

  let map: Message.event'<string, sourceEvent> => Spec.action<string, targetState>
  let sourceEventSchema: S.t<sourceEvent>
  let sourceName: string
  let subIdConfig: option<ReadModel_Spec.subIdConfig<targetState>>
  let targetStateSchema: S.t<targetState>
}

module type Mappings = {
  module Target: Projection_Spec.Target // to be removed via destructive replace in functor call
  module type Mapping = Mapping with type targetState = Target.state
  let mappings: array<module(Mapping)>
}

module type MappingImpl = {
  type sourceEvent
  type targetState
  let map: Message.event'<string, sourceEvent> => Spec.action<string, targetState>
}
