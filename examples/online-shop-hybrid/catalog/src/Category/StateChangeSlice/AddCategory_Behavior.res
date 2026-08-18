@@reventless.behavior

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  }

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name, categoryImage: ?categoryImage}) =>
    if state.exists {
      Error(CategoryAlreadyExists)
    } else {
      Ok([CategoryAdded({categoryId, name, categoryImage: ?categoryImage})])
    }
  }
