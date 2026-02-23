// AddCategory StateChangeSlice.
// Handles the AddCategory command; rejects duplicate creation via DCB optimistic concurrency.

open CatalogEventLog

let name = "AddCategory"

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

@schema
type error = | CategoryAlreadyExists

type decisionModel = {exists: bool, archived: bool}

let initialDecisionModel = {exists: false, archived: false}

let reduce = (model, event) =>
  switch event {
  | CategoryAdded(_) => {exists: true, archived: false}
  | CategoryArchived(_) => {...model, archived: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    if model.exists {
      Error(CategoryAlreadyExists)
    } else {
      Ok([CategoryAdded({categoryId, name})])
    }
  }
