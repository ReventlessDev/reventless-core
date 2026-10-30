// Customer projection mappings.
// Maps Customer aggregate events to Customers read model state changes.
@@reventless.mappings

module CustomerMapping = Mapping.Make(
  Customer,
  Customers,
  {
    open Customer
    let project = ({event, id, _}) =>
      switch event {
      // The read model holds plaintext; an erased customer's row is cleared by the
      // app's erasure, and a rebuild after it writes nothing in its place.
      | Registered({email, address}) =>
        Set(
          id,
          {
            Customers.email: email->Reventless.Pii.getOr(""),
            address: address->Reventless.Pii.getOr(""),
            deactivated: false,
          },
        )
      | EmailUpdated({email}) =>
        Update(id, state => {...state, email: email->Reventless.Pii.getOr("")})
      | AddressUpdated({address}) =>
        Update(id, state => {...state, address: address->Reventless.Pii.getOr("")})
      | Deactivated => Update(id, state => {...state, deactivated: true})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CustomerMapping)]
