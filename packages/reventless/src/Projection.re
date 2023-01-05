open ReventlessSpec.Projection.Spec;
open ReventlessSpec.QueryDb;

let handleActions =
    (actions, {ReventlessSpec.ReadModel.load, save, saveBatch, delete}) => {
  open Belt.Result;
  let actionResult =
    actions
    ->Belt.Array.map(action =>
        switch (action) {
        | Create(id, state) => [|save(. id, state, Init, None)|]
        | CreateMany(states) =>
          let batch =
            states->Belt.Array.map(((id, state)) => (id, state, None));
          [|saveBatch(. batch)|]; // TODO: think about using single saves with saveMode Init

        | Set(id, state) => [|save(. id, state, Any, None)|]
        | SetMany(ids, set) =>
          let batch = ids->Belt.Array.map(id => (id, set(id), None));
          [|saveBatch(. batch)|];

        | Update(id, update) => [|
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
              ),
          |]
        | UpdateWithDefault(id, default, update) => [|
            load(. id)
            ->Js.Promise.then_(
                fun
                | Ok(states) =>
                  switch (states) {
                  | [] => save(. id, default, Init, None)
                  | [state] =>
                    let newState = state->update;
                    save(. id, newState, Overwrite, None);
                  | _ => Error(StaleState)->Js.Promise.resolve
                  }
                | Error(err) => Error(err)->Js.Promise.resolve,
                _,
              ),
          |]
        | UpdateMultiState(id, update) => [|
            load(. id)
            ->Js.Promise.then_(
                fun
                | Ok([]) => Ok()->Js.Promise.resolve
                | Ok(states) => {
                    let newStates = states->Belt.List.toArray->update;
                    saveBatch(.
                      newStates->Belt.Array.map(newState =>
                        (id, newState, None)
                      ),
                    );
                  }
                | Error(err) => Error(err)->Js.Promise.resolve,
                _,
              ),
          |]

        | Delete(id) => [|delete(. id, None)|]
        | DeleteMany(ids) => ids->Belt.Array.map(id => delete(. id, None))

        // TODO: add missing actions
        | _ => [|Ok()->Js.Promise.resolve|]
        }
      )
    ->Belt.Array.concatMany;
  actionResult;
};
