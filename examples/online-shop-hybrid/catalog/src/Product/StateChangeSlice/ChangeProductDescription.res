// ChangeProductDescription StateChangeSlice.
// Requires product to exist; idempotent when description is unchanged.

open Reventless
open CatalogEventLog

let name = "ChangeProductDescription"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  ChangeProductDescription({productId: @s.matches(DcbTag.string) string, description: string})

@schema
type error = ProductNotFound

type decisionModel = {exists: bool, currentDescription: string}

let initialDecisionModel = {exists: false, currentDescription: ""}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({description}) => {exists: true, currentDescription: description}
  | ProductDescriptionChanged({description}) => {
      ...model,
      currentDescription: description,
    }
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ChangeProductDescription({productId, description}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if description == model.currentDescription {
      Ok([]) // idempotent — description unchanged
    } else {
      Ok([ProductDescriptionChanged({productId, description})])
    }
  }
