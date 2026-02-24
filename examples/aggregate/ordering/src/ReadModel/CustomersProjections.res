// Customer projection mappings.
// Maps Customer aggregate events to Customers read model state changes.

open ReventlessSpec.Message
open ReventlessSpec.Projection
open Customer

module CustomerMapping = Mapping.Make(
  Customer,
  CustomersReadModel,
  {
    let map = ({event, id, _}) =>
      switch event {
      | CustomerRegistered({customerId, email, address}) =>
        Set(id, {CustomersReadModel.customerId, email, address, deactivated: false})
      | EmailUpdated({email}) => Update(id, state => {...state, email})
      | AddressUpdated({address}) => Update(id, state => {...state, address})
      | CustomerDeactivated(_) => Update(id, state => {...state, deactivated: true})
      }
  },
)

module Mappings = Mappings.Make(CustomersReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(CustomerMapping)]
