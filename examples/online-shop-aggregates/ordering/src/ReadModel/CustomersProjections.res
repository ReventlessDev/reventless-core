// Customer projection mappings.
// Maps Customer aggregate events to Customers read model state changes.

open Reventless.Message
open Reventless.Projection

module CustomerMapping = Mapping.Make(
  Customer,
  CustomersReadModel,
  {
    open Customer
    let project = ({event, id, _}) =>
      switch event {
      | Registered({email, address}) =>
        Set(id, {CustomersReadModel.email: email, address, deactivated: false})
      | EmailUpdated({email}) => Update(id, state => {...state, email})
      | AddressUpdated({address}) => Update(id, state => {...state, address})
      | Deactivated => Update(id, state => {...state, deactivated: true})
      }
  },
)
