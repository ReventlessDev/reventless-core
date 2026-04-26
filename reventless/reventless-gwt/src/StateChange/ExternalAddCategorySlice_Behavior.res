// Implementation half — pure decision/projection functions for the external
// AddCategory StateChangeSlice. Pairs with [ExternalAddCategorySlice.res].

open ExternalAddCategorySlice

type state = {exists: bool, archived: bool}
let initialState: state = {exists: false, archived: false}

let evolve = (state: state, event: consumedEvent): state =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  }

let decide = (state: state, command: command): result<array<event>, error> =>
  switch command {
  | AddCategory({categoryId, name}) =>
    state.exists ? Error(CategoryAlreadyExists) : Ok([CategoryAdded({categoryId, name})])
  }
