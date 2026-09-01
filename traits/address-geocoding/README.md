# @reventlessdev/trait-address-geocoding

A **domain trait**: the reusable middle of turning an aggregate's address into a map
point without corrupting the aggregate's data. The rules are a module the host calls;
the types are the host's own. What it ships:

| Part | Where |
|---|---|
| The decision rules | `src/AddressGeocoding_Guards.res` (staleness, redelivery, the supplied pair) |
| The slice body | `src/AddressGeocoding_Translate.res` (`translate`, `exhaustedReason`) |
| The host contract, as a type | `src/AddressGeocoding.res` (`module type Binding`) |
| The conformance suite | `src/AddressGeocoding_Conformance.res` (`Make(Binding).register()`) |
| The emitter | `src/AddressGeocoding_Scaffold.res` (`emit(~config, ~into, ~tests)`) |

The rule modules are compiled code a host imports at runtime, so a change to them is a
behavior change for every host: version it `fix:`/`feat:` accordingly.

Most of this graft is not emitted at all. The four facts and the two `@noApi` report
commands are real constructors the host **splices** — `...AddressGeocoding.events` and
`...AddressGeocoding.reportCommands` — so the compiler carries them, annotations and
schema included. The emitter writes the outbound slice, which the host does not have
yet, and prints the arms that belong inside the aggregate, its behavior and the
projection: those interleave with the host's own state machine, and placing an arm in
an ordered `switch` is an AST operation a text splice gets silently wrong.

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

1. Run the emitter. Every `--key` is a field of its config, and it validates them, so
   run it once to be told what it wants:

```sh
pnpm exec graft-trait @reventlessdev/trait-address-geocoding \
  --into src/Customer --tests tests/Customer \
  --entity Customer --entityId customerId --created Registered \
  --createdFields 'email: string' --createdValues 'email: "alice@x.y"' \
  --externalSystem AwsLocation --transition Customers.Active
```

   It writes the slice, its translation body and the conformance binding — whole, so
   the suite below needs no hand-written file — and prints three patches.

2. Paste the three patches. The aggregate's is two spread lines and two public
   commands; the behavior's is the state fields and the `evolve` / `decide` arms; the
   projection's is the view's `geolocation` field and its arms. `@transition` and
   `@authorize` are yours: pass them as config or add them here.

   A host whose subject is not called `address`, or is not a `string`, gets the same
   graft with the constructors spelled out instead of spliced — pass `--subject`, and
   the printed patch says which of the two you got.

3. Run the emitted conformance binding — `tests/<…>/AddressGeocodingConformance_GWT.res`
   registers the suite as it stands, and it goes green once the patches are in. 13
   assertions, over your constructors, not the trait's.

4. Keep the capability declaration the emitter wrote onto the slice's spec, so the
   deployment is checked rather than trusted:

```rescript
let capabilityNeeds = TraitAddressGeocoding.AddressGeocoding.capabilityNeeds
```

   The declaration reaches the plugin's `capabilities.json`, the platform's
   generated capability list, and a deploy-time gate that refuses a plugin whose
   platform provisions no place index. Skip it and the deploy succeeds, the slice
   exhausts its retries, and every address is recorded as permanently
   unresolvable — with no error anywhere.

   The platform provisions the capability itself: `Capability_Geocoding_AwsLocation`
   on AWS, passed as `~geocoderPlaceIndex`; `Capabilities.none` locally, which
   answers `Unavailable` on purpose.

The specimen host is `examples/online-shop-hybrid/ordering` (`Customer`).
