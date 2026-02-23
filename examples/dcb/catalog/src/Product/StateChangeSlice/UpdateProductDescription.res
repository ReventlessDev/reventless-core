// UpdateProductDescription StateChangeSlice.
// Requires product to exist; idempotent when description is unchanged.

open CatalogEventLog

let name = "UpdateProductDescription"

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | UpdateProductDescription({
      productId: @s.matches(Reventless.DcbTag.string) string,
      description: string,
    })

@schema
type error = | ProductNotFound

type decisionModel = {exists: bool, currentDescription: string}

let initialDecisionModel = {exists: false, currentDescription: ""}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({description}) => {exists: true, currentDescription: description}
  | ProductDescriptionUpdated({description}) => {
      ...model,
      currentDescription: description,
    }
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | UpdateProductDescription({productId, description}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if description == model.currentDescription {
      Ok([]) // idempotent — description unchanged
    } else {
      Ok([ProductDescriptionUpdated({productId, description})])
    }
  }
