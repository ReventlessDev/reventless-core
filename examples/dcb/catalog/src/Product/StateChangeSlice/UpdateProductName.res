// UpdateProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.

open CatalogEventLog

let name = "UpdateProductName"

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | UpdateProductName({productId: @s.matches(Reventless.DcbTag.string) string, name: string})

@schema
type error = | ProductNotFound

type decisionModel = {exists: bool, currentName: string}

let initialDecisionModel = {exists: false, currentName: ""}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameUpdated({name}) => {...model, currentName: name}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | UpdateProductName({productId, name}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if name == model.currentName {
      Ok([]) // idempotent — name unchanged
    } else {
      Ok([ProductNameUpdated({productId, name})])
    }
  }
