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

type state = {exists: bool, currentDescription: string}

let initialState = {exists: false, currentDescription: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({description}) => {exists: true, currentDescription: description}
  | ProductDescriptionChanged({description}) => {
      ...state,
      currentDescription: description,
    }
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductDescription({productId, description}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if description == state.currentDescription {
      Ok([]) // idempotent — description unchanged
    } else {
      Ok([ProductDescriptionChanged({productId, description})])
    }
  }
