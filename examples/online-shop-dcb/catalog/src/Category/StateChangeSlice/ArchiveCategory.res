// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.

open Reventless
open CatalogEventLog

let name = "ArchiveCategory"

module DcbEventLogSpec = CatalogEventLog

@schema
type command = ArchiveCategory({categoryId: @s.matches(DcbTag.string) string})

@schema
type error = CategoryNotFound

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
  | ArchiveCategory({categoryId: theId}) =>
    if !model.exists {
      Error(CategoryNotFound)
    } else if model.archived {
      Ok([]) // idempotent — already archived
    } else {
      Ok([CategoryArchived({categoryId: theId})])
    }
  }
