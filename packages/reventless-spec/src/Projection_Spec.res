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
  let subIdConfig: option<ReadModel_Spec.subIdConfig<state>>
}

type action<'id, 'state> =
  | /** Create new state (not existing) */ Create('id, 'state)
  | /** Create many new states (if not exist) */ CreateMany(array<('id, 'state)>)
  | /** Update state (existing) */ Update('id, 'state => 'state)
  | /** Update many states (existing) */ UpdateMany(array<'id>, ('id, 'state) => 'state)
  | /** Update state (existing) or use default (not existing) */
  UpdateWithDefault('id, 'state, 'state => 'state)
  | /** Update many states (existing) or use default (not existing) */
  UpdateManyWithDefault(array<'id>, 'id => 'state, ('id, 'state) => 'state)
  | /** Set fixed state */ Set('id, 'state)
  | /** Set many fixed states */ SetMany(array<'id>, 'id => 'state)
  | /** Delete state */ Delete('id)
  | /** Delete state */ DeleteMany(array<'id>)
  | /** Delete state (conditional) */ DeleteIf('id, 'state => bool)
  | /** Delete many states (conditional) */ DeleteManyIf(array<'id>, ('id, 'state) => bool)
  | /** Create multiStates (multiple sub states with same id)*/ CreateMultiState('id, array<'state>)
  | /** Update multiState (Create/Update/Delete multiple sub states with same id) */
  UpdateMultiState('id, array<'state> => array<'state>)
  | /** Update many multiStates (Create/Update/Delete multiple states with same id each) */
  UpdateManyMultiStates(array<'id>, ('id, array<'state>) => array<'state>)
  | /** NoOp */ Ignore
