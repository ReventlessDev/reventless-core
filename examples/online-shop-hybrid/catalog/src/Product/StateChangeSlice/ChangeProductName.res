// ChangeProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.

open Reventless
open CatalogEventLog

let name = "ChangeProductName"

module DcbEventLogSpec = CatalogEventLog

@schema
type command = ChangeProductName({productId: @s.matches(DcbTag.string) string, name: string})

@schema
type error = ProductNotFound

type decisionModel = {exists: bool, currentName: string}

let initialDecisionModel = {exists: false, currentName: ""}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...model, currentName: name}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if name == model.currentName {
      Ok([]) // idempotent — name unchanged
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
