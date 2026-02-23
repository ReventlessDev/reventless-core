// ProductsView StateViewSlice.
// Projects product events from the shared catalog event log into a Products read model.

open ReventlessSpec.Projection
open CatalogEventLog

let name = "ProductsView"

module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {productId: string, name: string, description: string, price: float}

let project = (_, event) =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameUpdated({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionUpdated({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceUpdated({productId, price}) => [Update(productId, state => {...state, price})]
  | _ => [] // Category events are not handled by this view
  }
