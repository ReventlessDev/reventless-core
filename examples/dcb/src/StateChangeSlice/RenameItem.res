// RenameItem StateChangeSlice specification.
// Handles the RenameItem command; requires item to exist and not be archived.

let name = "RenameItem"

module DcbEventLogSpec = ItemEventLog

@schema
type command = | RenameItem({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})

@schema
type error =
  | ItemNotFound
  | ItemAlreadyArchived

type decisionModel = {exists: bool, archived: bool}

let initialDecisionModel = {exists: false, archived: false}

let reduce = (model, event) =>
  switch event {
  | ItemEventLog.ItemCreated(_) => {exists: true, archived: false}
  | ItemEventLog.ItemArchived(_) => {...model, archived: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RenameItem({itemId, newName}) =>
    if !model.exists {
      Error(ItemNotFound)
    } else if model.archived {
      Error(ItemAlreadyArchived)
    } else {
      Ok([ItemEventLog.ItemRenamed({itemId, newName})])
    }
  }
