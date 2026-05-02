@@reventless.projection

let project = event =>
  switch event {
  | CustomerRegistered({customerId, email, address}) => [
      Set(customerId, {customerId, email, address, deactivated: false}),
    ]
  | EmailChanged({customerId, email}) => [Update(customerId, state => {...state, email})]
  | AddressChanged({customerId, address}) => [Update(customerId, state => {...state, address})]
  | CustomerDeactivated({customerId}) => [
      Update(customerId, state => {...state, deactivated: true}),
    ]
  }
