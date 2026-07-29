// Product projection mappings.
// Maps Product aggregate events to Products read model state changes.
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  Products,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, description, price, imageUrl}) =>
        Set(id, {Products.name: name, description, price, imageUrl})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | DescriptionUpdated({description}) =>
        Update(id, state => {...state, description})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      | ImageUpdated({imageUrl}) => Update(id, state => {...state, imageUrl})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
