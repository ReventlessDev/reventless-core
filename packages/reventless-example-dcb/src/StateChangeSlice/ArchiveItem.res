// ArchiveItem StateChangeSlice specification.
// Handles the ArchiveItem command; requires item to exist; idempotent if already archived.

let name = "ArchiveItem"

module DcbEventLogSpec = ItemEventLog

@schema
type command = | ArchiveItem({itemId: @s.matches(Reventless.DcbTag.string) string})

@schema
type error = | ItemNotFound

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
  | ArchiveItem({itemId: theId}) =>
    if !model.exists {
      Error(ItemNotFound)
    } else if model.archived {
      Ok([]) // idempotent — already archived
    } else {
      Ok([ItemEventLog.ItemArchived({itemId: theId})])
    }
  }
