# @reventlessdev/trait-address-geocoding

A **domain trait**: the reusable middle of turning an aggregate's address into a map
point without corrupting the aggregate's data. It ships no runtime code. What it ships:

| Part | Where |
|---|---|
| The host contract, as a type | `src/AddressGeocoding.res` (`module type Binding`) |
| The conformance suite | `src/AddressGeocoding_Conformance.res` (`Make(Binding).register()`) |
| Scaffold templates for the graft | `templates/*.res.tpl` |

The confidence rule — what a geocoder's reply *means* — is core's
(`Reventless.Geocoding`, `Reventless.Geolocation`). This package owns how that reply is
grafted onto an aggregate:

- **`resolvedFrom` is a staleness token.** An answer for an address the entity has
  since changed is dropped, not applied.
- **Redelivery is a no-op.** The slice re-publishes on every heartbeat sweep until its
  TODO clears, so an unchanged answer must not append a duplicate event.
- **An outage is not a verdict.** `Unavailable` retries; `NoMatch` records a fact.
- **The stand-down.** A client that supplies address and point together is not raced
  by the geocoder: the pair-supplying event is not in the slice's consumed set.
- **Two state fields** (`location` + `locationResolvedFrom`), because never-asked,
  found, and tried-and-found-wanting do not fit in one `option`.

## Grafting a host

1. Paste the `templates/` into the aggregate, its behavior, an outbound translation
   slice and the read model, replacing `{{Entity}}`, `{{entityId}}`, `{{Subject}}`,
   `{{subject}}`, `{{Created}}` and `{{Slice}}`. The scaffolding is by hand on purpose.
2. Bind the host in a `_GWT.res` test file and run the suite:

```rescript
module Binding = {
  type subject = string
  let subjectText = s => s
  let subjectA = "Stephansplatz 1, Vienna"
  let subjectB = "Kärntner Straße 1, Vienna"
  let posture = TraitAddressGeocoding.AddressGeocoding.WritesBack

  module Spec = Customer
  module Behavior = Customer_Behavior
  let created = address => [Customer.Registered({email: "a@x.y", address})]
  // … the remaining constructors, see `module type Binding`
}

TraitAddressGeocoding.AddressGeocoding_Conformance.Make(Binding).register()
```

3. Requires the `geocode` capability; the platform provisions it
   (`Capability_Geocoding_AwsLocation` on AWS, `Capabilities.none` locally).

The specimen host is `examples/online-shop-hybrid/ordering` (`Customer`).
