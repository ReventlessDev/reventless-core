// CategoriesView StateViewSlice.
// Projects category events from the shared catalog event log into a Categories read model.

open ReventlessSpec.Projection
open CatalogEventLog

let name = "CategoriesView"

module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {categoryId: string, name: string, archived: bool}

let project = (_, event) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [
      Set(categoryId, {categoryId, name, archived: false}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  | _ => [] // Product events are not handled by this view
  }
