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
      | Registered({email, address}) =>
        Set(id, {Customers.email: email, address, deactivated: false})
      | EmailUpdated({email}) => Update(id, state => {...state, email})
      | AddressUpdated({address}) => Update(id, state => {...state, address})
      | Deactivated => Update(id, state => {...state, deactivated: true})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CustomerMapping)]
