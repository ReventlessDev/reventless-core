// The address-geocoding trait's conformance suite, bound to `Customer`. The
// graft rules are asserted by the trait; this file only says what the host calls
// things. Emitted whole: every name here is one the graft already declared.

module Binding = {
  type subject = string
  let subjectText = s => s
  let subjectA = "Stephansplatz 1, Vienna"
  let subjectB = "Kärntner Straße 1, Vienna"
  let posture = TraitAddressGeocoding.AddressGeocoding.WritesBack

  module Spec = Customer
  module Decision = Customer_Decision

  let created = address => [
    Customer.Registered({email: Value("alice@x.y"), address: Value(address)}),
  ]
  let subjectChanged = address => Customer.AddressUpdated({address: Value(address)})
  let located = (~point, ~resolvedFrom) => Customer.LocationSet({
    location: point,
    resolvedFrom: Value(resolvedFrom),
  })
  let unresolvable = (~subject, ~reason) => Customer.AddressUnresolvable({
    address: Value(subject),
    reason,
  })
  let setLocation = (~point, ~resolvedFrom) => Customer.SetLocation({location: point, resolvedFrom})
  let markUnresolvable = (~subject, ~reason) => Customer.MarkAddressUnresolvable({
    address: subject,
    reason,
  })

  module Slice = {
    include GeocodeCustomerAddress
    let collect = GeocodeCustomerAddress_Translation.collect
  }
  let translate = GeocodeCustomerAddress_Translation.translate
  let item = (~entityId, ~subject) => {
    GeocodeCustomerAddress.customerId: entityId,
    address: subject,
  }
  // Every event type the slice consumes appears here — the consumed set may
  // not be wider than its triggers, and the suite checks exactly that.
  let triggers = address => [
    GeocodeCustomerAddress.Registered({email: Value("alice@x.y"), address: Value(address)}),
    GeocodeCustomerAddress.AddressUpdated({address: Value(address)}),
  ]
  // The stand-down, as a real constructor rather than a type name: a
  // misspelled name would pass the assertion for the wrong reason.
  let standsDownOn = [
    Customer.AddressLocated({address: Value(subjectA), location: {lat: 0.0, lng: 0.0}}),
  ]
  let isLocation = (cmd: GeocodeCustomerAddress.inboundCommand) =>
    switch cmd {
    | SetLocation(_) => true
    | MarkAddressUnresolvable(_) => false
    }
  let isVerdict = (cmd: GeocodeCustomerAddress.inboundCommand) => !isLocation(cmd)
}

module Conformance = TraitAddressGeocoding.AddressGeocoding_Conformance.Make(Binding)

Conformance.register()
