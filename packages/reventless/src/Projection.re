let handleActions =
    (actions, {ReventlessSpec.ReadModel.load, save, saveBatch, delete}) => {
  open Belt.Result;
  let actionResult =
    actions->Belt.Array.map(action =>
      switch (action) {
      | ReventlessSpec.Projection.Spec.Create(id, state) =>
        save(. id, state, Init, None)
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
              | [] =>
                Error(ReventlessSpec.QueryDb.StaleState)->Js.Promise.resolve
              | [state] =>
                let newState = state->update;
                save(. id, newState, Overwrite, None);
              | _ =>
                Error(ReventlessSpec.QueryDb.StaleState)->Js.Promise.resolve
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
  actionResult; // TODO: think about using single saves with saveMode Init
};
