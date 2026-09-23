// The first outbound translation slice fed by an Aggregate rather than a DCB event
// log, which is what makes `~sourceId` load-bearing: an aggregate's event payload
// does not name its own subject.
//
// `OutboundTranslation_GWT.Make` expects a single SliceSpec with `collect` at the
// top level, so compose it on locally. The graft rules — keying, outage-vs-verdict —
// are asserted by the trait's suite in `AddressGeocodingConformance_GWT.res`; what
// stays here is the host-specific wording of the answers.

module GeocodeCustomerAddressSlice = {
  include GeocodeCustomerAddress
  let collect = GeocodeCustomerAddress_Translation.collect
}

@@reventless.gwt

open Ordering_Examples

let vienna: Reventless.GeoPoint.t = {lat: 48.2082, lng: 16.3738}

// The real `translate`, driven by a stub geocoder. `whenTranslateMocked` takes any
// (id, item) => promise<translateResult>, so no DSL verb is needed to reach it.
let withGeocoder = (
  answer: result<array<Reventless.Geocoding.candidate>, Reventless.Geocoding.failure>,
) => {
  // Spread `none` and override the one capability under test: a literal record
  // would have to name every other capability the framework grows, and this test
  // has nothing to say about them.
  let capabilities: Reventless.Capabilities.t = {
    ...Reventless.Capabilities.none,
    geocode: (~text as _) => Promise.resolve(answer),
  }
  (id, item) => GeocodeCustomerAddress_Translation.translate(id, item, ~capabilities)
}

describe("GeocodeCustomerAddress OutboundTranslationSlice", () => {
  // scenario-id: 8b319e75-7826-4d3d-bd88-a43a197fb014
  test("a confident match completes the TODO", () =>
    givenTodo(
      "cust-1:Stephansplatz 1, Vienna",
      {
        customerId: cust1,
        address: viennaAddress,
      },
    )
    ->whenTranslateMocked(
      (_id, item) =>
        Promise.resolve(
          Ok(Some((item.customerId, SetLocation({location: vienna, resolvedFrom: item.address})))),
        ),
    )
    ->thenTodoStatus("cust-1:Stephansplatz 1, Vienna", #Completed)
  )

  // The real `translate`, not a mock of it: a confident answer becomes SetLocation
  // with the point the geocoder returned.
  // scenario-id: e630a084-41b4-4155-979a-8bb03552ba52
  test("translate: a confident answer produces SetLocation", () =>
    givenTodo(
      "cust-1:Stephansplatz 1, Vienna",
      {
        customerId: cust1,
        address: viennaAddress,
      },
    )
    ->whenTranslateMocked(
      withGeocoder(
        Ok([
          {
            label: "Stephansplatz 1, Vienna",
            point: vienna,
            relevance: Some(0.995),
          },
        ]),
      ),
    )
    ->thenCommand("cust-1", SetLocation({location: vienna, resolvedFrom: viennaAddress}))
  )

  // An ambiguous answer is a verdict, and the reason names both candidates rather
  // than saying only that there was no confident match.
  // scenario-id: 93103dd6-1304-42b1-83f9-fd4ac4a90160
  test("translate: an ambiguous answer produces a reason naming the candidates", () =>
    givenTodo("cust-1:Springfield", {customerId: cust1, address: "Springfield"})
    ->whenTranslateMocked(
      withGeocoder(
        Ok([
          {
            label: "Springfield, IL",
            point: vienna,
            relevance: Some(0.99),
          },
          {
            label: "Springfield, MA",
            point: vienna,
            relevance: Some(0.985),
          },
        ]),
      ),
    )
    ->thenCommand(
      "cust-1",
      MarkAddressUnresolvable({
        address: "Springfield",
        reason: `"Springfield" matched "Springfield, IL" and "Springfield, MA" about equally well`,
      }),
    )
  )
})
