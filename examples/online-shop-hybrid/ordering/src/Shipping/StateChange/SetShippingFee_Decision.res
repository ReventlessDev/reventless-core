@@reventless.decision

// Each method's fee, by the method's name; the latest one set stands.
type state = array<(string, Reventless.Money.t)>

let initialState: state = []

let methodId = method =>
  switch method {
  | Standard => "Standard"
  | Express => "Express"
  | Pickup => "Pickup"
  }

let evolve = (state, event) =>
  switch event {
  | ShippingFeeSet({shippingMethodId, fee}) =>
    state
    ->Array.filter(((id, _)) => id != shippingMethodId)
    ->Array.concat([(shippingMethodId, fee)])
  }

let decide = (state, command) =>
  switch command {
  | SetShippingFee({fee}) if fee.minorUnits < 0. => Error(NegativeFee)
  | SetShippingFee({shippingMethod, fee}) =>
    let shippingMethodId = methodId(shippingMethod)
    switch state->Array.find(((id, _)) => id == shippingMethodId) {
    | Some((_, current)) if current == fee => Ok([]) // idempotent — fee unchanged
    | _ => Ok([ShippingFeeSet({shippingMethodId, fee})])
    }
  }
