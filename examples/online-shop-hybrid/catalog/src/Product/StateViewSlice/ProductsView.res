// ProductsView StateViewSlice.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

open Reventless.Projection

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: float})

@schema
type state = {productId: string, name: string, description: string, price: float}

let project = event =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  }
