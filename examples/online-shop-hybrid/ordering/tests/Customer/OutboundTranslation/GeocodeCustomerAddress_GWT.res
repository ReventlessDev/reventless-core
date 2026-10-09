// The first outbound translation slice fed by an Aggregate rather than a DCB event
// log, which is what makes `~sourceId` load-bearing: an aggregate's event payload
// does not name its own subject.
//
// The graft rules — keying, outage-vs-verdict — are asserted by the trait's suite
// in `AddressGeocodingConformance_GWT.res`; what stays here is the host-specific
// wording of the answers.

@@reventless.gwt

open Ordering_Examples

let vienna: Reventless.GeoPoint.t = {lat: 48.2082, lng: 16.3738}

// The real `translate`, against a geocoder that answers `answer`.
let geocoder = answer => fakes(~geocode=async (~text as _) => answer, ())

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
    ->givenCapabilities(
      geocoder(
        Ok([
          {
            label: "Stephansplatz 1, Vienna",
            point: vienna,
            relevance: Some(0.995),
          },
        ]),
      ),
    )
    ->whenTranslated
    ->thenCommand("cust-1", SetLocation({location: vienna, resolvedFrom: viennaAddress}))
  )

  // An ambiguous answer is a verdict, and the reason names both candidates rather
  // than saying only that there was no confident match.
  // scenario-id: 93103dd6-1304-42b1-83f9-fd4ac4a90160
  test("translate: an ambiguous answer produces a reason naming the candidates", () =>
    givenTodo("cust-1:Springfield", {customerId: cust1, address: "Springfield"})
    ->givenCapabilities(
      geocoder(
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
    ->whenTranslated
    ->thenCommand(
      "cust-1",
      MarkAddressUnresolvable({
        address: "Springfield",
        reason: `"Springfield" matched "Springfield, IL" and "Springfield, MA" about equally well`,
      }),
    )
  )

  // The address is what is asked, as written.
  test("translate: the geocoder is asked for the address as written", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {customerId: cust1, address: viennaAddress})
    ->givenCapabilities(geocoder(Ok([])))
    ->whenTranslated
    ->thenSent([Geocoded({text: viennaAddress})])
  )

  // An outage is not a verdict: the row stays open for the next sweep.
  test("translate: a geocoder that is down leaves the row to be retried", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {customerId: cust1, address: viennaAddress})
    ->givenCapabilities(geocoder(Error(Unavailable("timeout"))))
    ->whenTranslated
    ->thenTodoStatus("cust-1:Stephansplatz 1, Vienna", #Failed)
  )

  // The budget ran out with the geocoder never answering: the verdict is recorded
  // rather than leaving the row pending forever.
  test("exhausted: the address is recorded as unresolvable", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {customerId: cust1, address: viennaAddress})
    ->whenExhausted(~lastError="timeout")
    ->thenCommand(
      "cust-1",
      MarkAddressUnresolvable({
        address: viennaAddress,
        reason: GeocodeCustomerAddress_Translation.Geocode.exhaustedReason(Some("timeout")),
      }),
    )
  )
})
