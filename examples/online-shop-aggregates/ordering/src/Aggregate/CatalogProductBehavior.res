// CatalogProduct aggregate behavior.
// Idempotently syncs Catalog product state into Ordering.

open Reventless
open CatalogProduct

module Spec = CatalogProduct

@schema
type state = {name: string, price: float}

let resolverConfig = {Behavior.commandSchema, fields: []}

let moduleUrl: string = %raw(`import.meta.url`)

let init = event =>
  switch event {
  | Synced({name, price}) => {name, price}
  | PriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | Synced({name, price}) => {name, price}
  | PriceUpdated({price}) => {...state, price}
  }

let create = (command, _context, _errorHandler) =>
  switch command {
  | Sync({name, price}) => [Synced({name, price})]
  | UpdatePrice(_) => [] // no aggregate yet — idempotent
  }

let execute = (_state, command, _context, _errorHandler) =>
  switch command {
  | Sync(_) => [] // already exists — idempotent
  | UpdatePrice({price}) => [PriceUpdated({price: price})]
  }
