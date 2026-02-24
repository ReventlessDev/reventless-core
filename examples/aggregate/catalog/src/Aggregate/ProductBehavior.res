// Product aggregate behavior.
// Implements the state machine for adding and updating products.

open ReventlessSpec
open Product

module Spec = Product

@schema
type state = {name: string, description: string, price: float}

let resolverConfig = {
  Behavior.commandSchema,
  fields: [],
}

let init = event =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated(_)
  | ProductDescriptionUpdated(_)
  | ProductPriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated({name}) => {...state, name}
  | ProductDescriptionUpdated({description}) => {...state, description}
  | ProductPriceUpdated({price}) => {...state, price}
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | AddProduct({productId, name, description, price}) => [
      ProductAdded({productId, name, description, price}),
    ]
  | UpdateProductName(_)
  | UpdateProductDescription(_)
  | UpdateProductPrice(_) =>
    errorHandler(ProductNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch command {
  | AddProduct(_) => errorHandler(ProductAlreadyExists, command, context)
  | UpdateProductName({name}) if name == state.name => []
  | UpdateProductName({productId, name}) => [ProductNameUpdated({productId, name})]
  | UpdateProductDescription({description}) if description == state.description => []
  | UpdateProductDescription({productId, description}) => [
      ProductDescriptionUpdated({productId, description}),
    ]
  | UpdateProductPrice({price}) if price == state.price => []
  | UpdateProductPrice({productId, price}) => [ProductPriceUpdated({productId, price})]
  }
