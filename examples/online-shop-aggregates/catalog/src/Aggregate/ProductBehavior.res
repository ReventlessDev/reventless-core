// Product aggregate behavior.
// Implements the state machine for adding and updating products.

open Reventless
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
  | Added({name, description, price}) => {name, description, price}
  | NameUpdated(_)
  | DescriptionUpdated(_)
  | PriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | Added({name, description, price}) => {name, description, price}
  | NameUpdated({name}) => {...state, name}
  | DescriptionUpdated({description}) => {...state, description}
  | PriceUpdated({price}) => {...state, price}
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | Add({name, description, price}) => [
      Added({name, description, price}),
    ]
  | UpdateName(_)
  | UpdateDescription(_)
  | UpdatePrice(_) =>
    errorHandler(ProductNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch command {
  | Add(_) => errorHandler(ProductAlreadyExists, command, context)
  | UpdateName({name}) if name == state.name => []
  | UpdateName({name}) => [NameUpdated({name: name})]
  | UpdateDescription({description}) if description == state.description => []
  | UpdateDescription({description}) => [
      DescriptionUpdated({description: description}),
    ]
  | UpdatePrice({price}) if price == state.price => []
  | UpdatePrice({price}) => [PriceUpdated({price: price})]
  }
