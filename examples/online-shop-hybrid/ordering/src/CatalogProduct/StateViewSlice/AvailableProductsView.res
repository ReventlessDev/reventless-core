// AvailableProductsView StateViewSlice.
// Projects synced catalog product events into a queryable "available products" read model.

open Reventless.Projection
open OrderingEventLog

let name = "AvailableProductsView"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type event = OrderingEventLog.event

@schema
type state = {productId: string, name: string, price: float}

let project = event =>
  switch event {
  | CatalogProductSynced({productId, name, price}) => [Set(productId, {productId, name, price})]
  | CatalogProductPriceChanged({productId, price}) =>
    [Update(productId, p => {...p, price})]
  | _ => []
  }
