// CreateItem StateChangeSlice specification.
// Handles the CreateItem command; rejects duplicates via DCB optimistic concurrency.

let name = "CreateItem"

module DcbEventLogSpec = ItemEventLog

@schema
type command = | CreateItem({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})

@schema
type error = | ItemAlreadyExists

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
  | CreateItem({itemId, name}) =>
    if model.exists {
      Error(ItemAlreadyExists)
    } else {
      Ok([ItemEventLog.ItemCreated({itemId, name})])
    }
  }
