// AddProduct StateChangeSlice.
// Handles the AddProduct command; rejects duplicate creation via DCB optimistic concurrency.

open Reventless
open CatalogEventLog

let name = "AddProduct"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | AddProduct({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

type decisionModel = {exists: bool}

let initialDecisionModel = {exists: false}

let reduce = (model, event) =>
  switch event {
  | ProductAdded(_) => {exists: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if model.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
