@ocaml.doc(" see ReventlessSpec.AggregateSpec.T ")
module type Source = {
  module Id: Id.T
  let name: string
  @decco
  type event
}

module type Target = {
  module Id: Id.T
  let name: string
  @decco
  type state
  let subIdConfig: option<ReadModel.Spec.subIdConfig<state>>
}

type action<'id, 'state> =
  | @ocaml.doc(" Create new state (not existing) ") Create('id, 'state)
  | @ocaml.doc(" Create many new states (if not exist) ") CreateMany(array<('id, 'state)>)
  | @ocaml.doc(" Update state (existing) ") Update('id, 'state => 'state)
  | @ocaml.doc(" Update many states (existing) ") UpdateMany(array<'id>, ('id, 'state) => 'state)
  | @ocaml.doc(" Update state (existing) or use default (not existing) ")
  UpdateWithDefault('id, 'state, 'state => 'state)
  | @ocaml.doc(" Update many states (existing) or use default (not existing) ")
  UpdateManyWithDefault(array<'id>, 'id => 'state, ('id, 'state) => 'state)
  | @ocaml.doc(" Set fixed state ") Set('id, 'state)
  | @ocaml.doc(" Set many fixed states ") SetMany(array<'id>, 'id => 'state)
  | @ocaml.doc(" Delete state ") Delete('id)
  | @ocaml.doc(" Delete state ") DeleteMany(array<'id>)
  | @ocaml.doc(" Delete state (conditional) ") DeleteIf('id, 'state => bool)
  | @ocaml.doc(" Delete many states (conditional) ") DeleteManyIf(array<'id>, ('id, 'state) => bool)
  | @ocaml.doc(" Create multiStates (multiple sub states with same id)")
  CreateMultiState('id, array<'state>)
  | @ocaml.doc(" Update multiState (Create/Update/Delete multiple sub states with same id)")
  UpdateMultiState('id, array<'state> => array<'state>)
  | @ocaml.doc(" Update many multiStates (Create/Update/Delete multiple states with same id each)")
  UpdateManyMultiStates(array<'id>, ('id, array<'state>) => array<'state>)
  | @ocaml.doc(" NoOp ") Ignore
