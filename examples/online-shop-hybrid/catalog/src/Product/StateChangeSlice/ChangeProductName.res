// ChangeProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.

open Reventless

let name = "ChangeProductName"
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool, currentName: string}

let initialState = {exists: false, currentName: ""}

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  }

@schema
type command = ChangeProductName({productId: @s.matches(DcbTag.string) string, name: string})

@schema
type error = ProductNotFound

@schema
type producedEvent =
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name: string})

let decide = (state, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if name == state.currentName {
      Ok([]) // idempotent — name unchanged
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
