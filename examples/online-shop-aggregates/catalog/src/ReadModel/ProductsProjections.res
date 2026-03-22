// Product projection mappings.
// Maps Product aggregate events to Products read model state changes.

open Reventless.Message
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductsReadModel,
  {
    open Product
    let map = ({event, id, _}) =>
      switch event {
      | Added({name, description, price}) =>
        Set(id, {ProductsReadModel.name: name, description, price})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | DescriptionUpdated({description}) =>
        Update(id, state => {...state, description})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)
