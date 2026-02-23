module type Source = {
  module Id: Id.T
  let name: string
  @schema
  type event
}

module type Target = {
  module Id: Id.T
  let name: string
  @schema
  type state
  let subIdConfig: option<ReadModel.subIdConfig<state>>
}

type action<'id, 'state> =
  /** Create new state (not existing) */
  | Create('id, 'state)
  /** Create many new states (if not exist) */
  | CreateMany(array<('id, 'state)>)
  /** Update state (existing) */
  | Update('id, 'state => 'state)
  /** Update many states (existing) */
  | UpdateMany(array<'id>, ('id, 'state) => 'state)
  /** Update state (existing) or use default (not existing) */
  | UpdateWithDefault('id, 'state, 'state => 'state)
  /** Update many states (existing) or use default (not existing) */
  | UpdateManyWithDefault(array<'id>, 'id => 'state, ('id, 'state) => 'state)
  /** Set fixed state */
  | Set('id, 'state)
  /** Set many fixed states */
  | SetMany(array<'id>, 'id => 'state)
  /** Delete state */
  | Delete('id)
  /** Delete state */
  | DeleteMany(array<'id>)
  /** Delete state (conditional) */
  | DeleteIf('id, 'state => bool)
  /** Delete many states (conditional) */
  | DeleteManyIf(array<'id>, ('id, 'state) => bool)
  /** Create multiStates (multiple sub states with same id)*/
  | CreateMultiState('id, array<'state>)
  /** Update multiState (Create/Update/Delete multiple sub states with same id) */
  | UpdateMultiState('id, array<'state> => array<'state>)
  /** Update many multiStates (Create/Update/Delete multiple states with same id each) */
  | UpdateManyMultiStates(array<'id>, ('id, array<'state>) => array<'state>)
  /** NoOp */
  | Ignore

module type Mapping = {
  //module Source: Source
  //module Target: Target // NOTE: to be destructive substituted
  module SourceId: Id.T
  @schema
  type sourceEvent
  @schema
  type targetState

  let map: Message.event'<string, sourceEvent> => action<string, targetState>
  let sourceEventSchema: S.t<sourceEvent>
  let sourceName: string
  let subIdConfig: option<ReadModel.subIdConfig<targetState>>
  let targetStateSchema: S.t<targetState>
}

module type Mappings = {
  module Target: Target // to be removed via destructive replace in functor call
  module type Mapping = Mapping with type targetState = Target.state
  let mappings: array<module(Mapping)>
}

module type MappingImpl = {
  type sourceEvent
  type targetState
  let map: Message.event'<string, sourceEvent> => action<string, targetState>
}
