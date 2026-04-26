// Implementation half — pairs with [WithManualOpen.res].

open WithManualOpen

type state = {exists: bool}
let initialState: state = {exists: false}

let evolve = (_state: state, event: consumedEvent): state =>
  switch event {
  | CategoryAdded => {exists: true}
  }

let decide = (state: state, command: command): result<array<event>, error> =>
  switch command {
  | AddCategory({categoryId, name}) =>
    state.exists ? Error(CategoryAlreadyExists) : Ok([CategoryAdded({categoryId, name})])
  }
