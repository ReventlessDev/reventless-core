@@reventless.projection

let project = ({event}) =>
  switch event {
  | CustomerRegistered({customerId, email, address}) => [
      // The view holds plaintext; an erased customer's row is cleared by the app's
      // erasure, and a rebuild after it writes nothing in its place.
      Set(
        customerId,
        {
          customerId,
          email: email->Reventless.Pii.getOr(""),
          address: address->Reventless.Pii.getOr(""),
          deactivated: false,
        },
      ),
    ]
  | EmailChanged({customerId, email}) => [
      Update(customerId, state => {...state, email: email->Reventless.Pii.getOr("")}),
    ]
  | AddressChanged({customerId, address}) => [
      Update(customerId, state => {...state, address: address->Reventless.Pii.getOr("")}),
    ]
  | CustomerDeactivated({customerId}) => [
      Update(customerId, state => {...state, deactivated: true}),
    ]
  }
