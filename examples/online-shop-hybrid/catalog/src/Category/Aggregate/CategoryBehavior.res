// Category aggregate behavior.
// Implements the state machine for adding, renaming, and archiving categories.

open Category

module Spec = Category

@schema
type state =
  | NotCreated
  | Active({name: string})
  | Archived

let resolverConfig = {
  Reventless.Behavior.commandSchema,
  fields: [],
}

let moduleUrl: string = %raw(`import.meta.url`)

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name})) => Active({name: name})
  | (Active(_), Added({name})) => Active({name: name})
  | (Active(_), Renamed({name})) => Active({name: name})
  | (Active(_), Category.Archived) => Archived
  | (Archived, _) => state
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name})) => Ok([Added({name: name})])
  | (NotCreated, Rename(_)) => Error(CategoryNotFound)
  | (NotCreated, Archive) => Error(CategoryNotFound)
  | (Active(_), Add(_)) => Error(CategoryAlreadyExists)
  | (Active(s), Rename({name})) when name == s.name => Ok([])
  | (Active(_), Rename({name})) => Ok([Renamed({name: name})])
  | (Active(_), Archive) => Ok([Category.Archived])
  | (Archived, Add(_)) => Error(CategoryAlreadyArchived)
  | (Archived, Rename(_)) => Error(CategoryAlreadyArchived)
  | (Archived, Archive) => Ok([]) // idempotent
  }
