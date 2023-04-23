module Spec = Projection_Spec

type encode<'a> = 'a => Js.Json.t
type decode<'a> = Js.Json.t => Belt.Result.t<'a, Decco.decodeError>
module type Mapping = {
  //module Source: Projection_Spec.Source
  //module Target: Projection_Spec.Target // NOTE: to be destructive substituted
  module SourceId: Id.T
  type sourceEvent
  type targetState
  let map: Message.event'<string, sourceEvent> => Spec.action<string, targetState>
  let sourceEvent_decode: decode<sourceEvent> // TODO: is it possible to remove Decco here?
  let sourceEvent_encode: encode<sourceEvent> // TODO: is it possible to remove Decco here?
  let sourceName: string
  let subIdConfig: option<ReadModelSpec.subIdConfig<targetState>>
  let targetState_encode: encode<targetState>
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


