/** see ReventlessSpec.AggregateSpec.T */
module type Source = {
  module Id: Id.T;
  let name: string;
  [@decco]
  type event;
};

module type Target = {
  module Id: Id.T;
  let name: string;
  [@decco]
  type state;
};

module ToGenericSource = (Source: Source) =>
  Mapper.MakeGenericSourceFromEventSource(Source);
module ToGenericTarget = (Target: Target) =>
  Mapper.MakeGenericTargetFromStateTarget(Target);

// type id = string;

type action('id, 'state) =
  | /** Create new state (not existing) */
    Create('id, 'state)
  | /** Create many new states (if not exist) */
    CreateMany(
      array(('id, 'state)),
    )
  | /** Update state (existing) */
    Update('id, 'state => 'state)
  | /** Update many states (existing) */
    UpdateMany(
      array('id),
      ('id, 'state) => 'state,
    )
  | /** Update state (existing) or use default (not existing) */
    UpdateWithDefault(
      'id,
      'state,
      'state => 'state,
    )
  | /** Update many states (existing) or use default (not existing) */
    UpdateManyWithDefault(
      array('id),
      'id => 'state,
      ('id, 'state) => 'state,
    )
  | /** Set fixed state */
    Set('id, 'state)
  | /** Set many fixed states */
    SetMany(array('id), 'id => 'state)
  | /** Delete state */
    Delete('id)
  | /** Delete state */
    DeleteMany(array('id))
  | /** Delete state (conditional) */
    DeleteIf('id, 'state => bool)
  | /** Delete many states (conditional) */
    DeleteManyIf(
      array('id),
      ('id, 'state) => bool,
    )
  | /** Update multiState (Create/Update/Delete multiple states with same id)*/
    UpdateMultiState(
      'id,
      array('state) => array('state),
    )
  | /** Update many multiStates (Create/Update/Delete multiple states with same id each)*/
    UpdateManyMultiStates(
      array('id),
      ('id, array('state)) => array('state),
    )
  | /** NoOp */
    Ignore;

// type primitives('id, 'state) = ReadModel.primitives('id, 'state);
// type error = QueryDb.storageError;

open Belt.Result;
open QueryDb;
let handleActions = (actions, {ReadModel.load, save, saveBatch, delete}) =>
  actions->Belt.Array.map(action =>
    switch (action) {
    | Create(id, state) => save(. id, state, Init, None)
    | CreateMany(states) =>
      let batch =
        states->Belt.Array.map(((id, state)) => (id, state, None));
      saveBatch(. batch); // TODO: think about using single saves with saveMode Init
    | Update(id, update) =>
      load(. id)
      ->Js.Promise.then_(
          fun
          | Ok(states) =>
            switch (states) {
            | [] => Error(StaleState)->Js.Promise.resolve
            | [state] =>
              let newState = state->update;
              save(. id, newState, Overwrite, None);
            | _ => Error(StaleState)->Js.Promise.resolve
            }
          | Error(err) => Error(err)->Js.Promise.resolve,
          _,
        )
    | UpdateMultiState(id, update) =>
      load(. id)
      ->Js.Promise.then_(
          fun
          | Ok(states) => {
              let newStates = states->Belt.List.toArray->update;
              saveBatch(.
                newStates->Belt.Array.map(newState => (id, newState, None)),
              );
            }
          | Error(err) => Error(err)->Js.Promise.resolve,
          _,
        )
    | Delete(id) => delete(. id, None)
    | _ => Ok()->Js.Promise.resolve
    }
  );
