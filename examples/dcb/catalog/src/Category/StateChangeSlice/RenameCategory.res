// RenameCategory StateChangeSlice.
// Requires category to exist and not be archived.

open ReventlessSpec
open CatalogEventLog

let name = "RenameCategory"

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | RenameCategory({categoryId: @s.matches(DcbTag.string) string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

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
  | RenameCategory({categoryId, name}) =>
    if !model.exists {
      Error(CategoryNotFound)
    } else if model.archived {
      Error(CategoryAlreadyArchived)
    } else {
      Ok([CategoryRenamed({categoryId, name})])
    }
  }
