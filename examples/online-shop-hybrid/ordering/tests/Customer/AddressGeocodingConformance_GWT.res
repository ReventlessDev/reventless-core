// The address-geocoding trait's conformance suite, bound to `Customer`. The graft
// rules are asserted by the trait; this file only says what the host calls things.

module Binding = {
  type subject = string
  let subjectText = s => s
  let subjectA = "Stephansplatz 1, Vienna"
  let subjectB = "Kärntner Straße 1, Vienna"
  let posture = TraitAddressGeocoding.AddressGeocoding.WritesBack

  module Spec = Customer
  module Behavior = Customer_Behavior

  let created = address => [Customer.Registered({email: "alice@x.y", address})]
  let subjectChanged = address => Customer.AddressUpdated({address: address})
  let located = (~point, ~resolvedFrom) => Customer.LocationSet({location: point, resolvedFrom})
  let unresolvable = (~subject, ~reason) => Customer.AddressUnresolvable({address: subject, reason})
  let setLocation = (~point, ~resolvedFrom) => Customer.SetLocation({location: point, resolvedFrom})
  let markUnresolvable = (~subject, ~reason) =>
    Customer.MarkAddressUnresolvable({address: subject, reason})

  module Slice = {
    include GeocodeCustomerAddress
    let collect = GeocodeCustomerAddress_Translation.collect
  }
  let translate = GeocodeCustomerAddress_Translation.translate
  let item = (~entityId, ~subject) => {GeocodeCustomerAddress.customerId: entityId, address: subject}
  let triggers = address => [
    GeocodeCustomerAddress.Registered({email: "alice@x.y", address}),
    GeocodeCustomerAddress.AddressUpdated({address: address}),
  ]
  let standsDownOn = [Customer.AddressLocated({address: subjectA, location: {lat: 0.0, lng: 0.0}})]
  let isLocation = (cmd: GeocodeCustomerAddress.inboundCommand) =>
    switch cmd {
    | SetLocation(_) => true
    | MarkAddressUnresolvable(_) => false
    }
  let isVerdict = (cmd: GeocodeCustomerAddress.inboundCommand) => !isLocation(cmd)
}

module Conformance = TraitAddressGeocoding.AddressGeocoding_Conformance.Make(Binding)

Conformance.register()
