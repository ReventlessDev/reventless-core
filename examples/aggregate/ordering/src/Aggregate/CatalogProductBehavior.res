// CatalogProduct aggregate behavior.
// Idempotently syncs Catalog product state into Ordering.

open Reventless
open CatalogProduct

module Spec = CatalogProduct

@schema
type state = {name: string, price: float}

let resolverConfig = {Behavior.commandSchema, fields: []}

let init = event =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceUpdated({price}) => {...state, price}
  }

let create = (command, _context, _errorHandler) =>
  switch command {
  | SyncNewProduct({productId, name, price}) => [CatalogProductSynced({productId, name, price})]
  | UpdateSyncedPrice(_) => [] // no aggregate yet — idempotent
  }

let execute = (_state, command, _context, _errorHandler) =>
  switch command {
  | SyncNewProduct(_) => [] // already exists — idempotent
  | UpdateSyncedPrice({productId, price}) => [CatalogProductPriceUpdated({productId, price})]
  }
