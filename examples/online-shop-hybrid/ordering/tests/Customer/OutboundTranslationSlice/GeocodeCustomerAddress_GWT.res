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

let vienna: Reventless.GeoPoint.t = {lat: 48.2082, lng: 16.3738}

// The real `translate`, driven by a stub geocoder. `whenTranslateMocked` takes any
// (id, item) => promise<translateResult>, so no DSL verb is needed to reach it.
let withGeocoder = (answer: result<array<Reventless.Geocoding.candidate>, Reventless.Geocoding.failure>) => {
  let capabilities: Reventless.Capabilities.t = {
    geocode: (~text as _) => Promise.resolve(answer),
  }
  (id, item) => GeocodeCustomerAddress_Translation.translate(id, item, ~capabilities)
}

let candidate = (~label, ~point=vienna, ~relevance): Reventless.Geocoding.candidate => {
  label,
  point,
  relevance: Some(relevance),
}

describe("GeocodeCustomerAddress OutboundTranslationSlice", () => {
  test("a confident match completes the TODO", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {
      customerId: "cust-1",
      address: "Stephansplatz 1, Vienna",
    })
    ->whenTranslateMocked((_id, item) =>
      Promise.resolve(
        Ok(Some((item.customerId, SetLocation({location: vienna, resolvedFrom: item.address})))),
      )
    )
    ->thenTodoStatus("cust-1:Stephansplatz 1, Vienna", #Completed)
  )

  // The real `translate`, not a mock of it: a confident answer becomes SetLocation
  // with the point the geocoder returned.
  test("translate: a confident answer produces SetLocation", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {
      customerId: "cust-1",
      address: "Stephansplatz 1, Vienna",
    })
    ->whenTranslateMocked(
      withGeocoder(Ok([candidate(~label="Stephansplatz 1, Vienna", ~relevance=0.995)])),
    )
    ->thenCommand("cust-1", SetLocation({location: vienna, resolvedFrom: "Stephansplatz 1, Vienna"}))
  )

  // An ambiguous answer is a verdict, and the reason names both candidates rather
  // than saying only that there was no confident match.
  test("translate: an ambiguous answer produces a reason naming the candidates", () =>
    givenTodo("cust-1:Springfield", {customerId: "cust-1", address: "Springfield"})
    ->whenTranslateMocked(
      withGeocoder(
        Ok([
          candidate(~label="Springfield, IL", ~relevance=0.99),
          candidate(~label="Springfield, MA", ~relevance=0.985),
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
