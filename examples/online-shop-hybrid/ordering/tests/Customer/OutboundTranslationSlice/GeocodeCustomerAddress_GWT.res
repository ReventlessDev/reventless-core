// The first outbound translation slice fed by an Aggregate rather than a DCB event
// log, which is what makes `~sourceId` load-bearing: an aggregate's event payload
// does not name its own subject.
//
// `OutboundTranslation_GWT.Make` expects a single SliceSpec with `collect` at the
// top level, so compose it on locally. The real `translate` reaches a geocoder and
// is mocked here; its own mapping is covered by `GeolocationTest`'s `ofSearch`
// cases, not by this file.

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
  // The customer id arrives from the event envelope, not the payload.
  testSync("collect: Registered queues a TODO carrying the customer from ~sourceId", () =>
    givenEvent(Registered({email: "alice@x.y", address: "Stephansplatz 1, Vienna"}))
    ->whenCollect(~sourceId="cust-1")
    ->thenTodos([
      ("cust-1:Stephansplatz 1, Vienna", {customerId: "cust-1", address: "Stephansplatz 1, Vienna"}),
    ])
  )

  testSync("collect: AddressUpdated queues the new address", () =>
    givenEvent(AddressUpdated({address: "Kärntner Straße 1, Vienna"}))
    ->whenCollect(~sourceId="cust-1")
    ->thenTodos([
      ("cust-1:Kärntner Straße 1, Vienna", {customerId: "cust-1", address: "Kärntner Straße 1, Vienna"}),
    ])
  )

  // Keyed by customer *and* address: keying by customer alone would make a
  // corrected address look like work already done.
  testSync("collect: a second address for the same customer is separate work", () =>
    givenEvent(AddressUpdated({address: "Kärntner Straße 1, Vienna"}))
    ->whenCollect(~sourceId="cust-1")
    ->thenTodos([
      ("cust-1:Kärntner Straße 1, Vienna", {customerId: "cust-1", address: "Kärntner Straße 1, Vienna"}),
    ])
  )

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

  // The one outcome that must not become a verdict: an outage is an Error, so the
  // TODO stays Pending for retry rather than recording a verdict on the address.
  // The sibling test below asserts the same thing from a mocked error string; this
  // one drives it from a real `Unavailable`.
  test("translate: an unavailable geocoder leaves the TODO Pending", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {
      customerId: "cust-1",
      address: "Stephansplatz 1, Vienna",
    })
    ->whenTranslateMocked(withGeocoder(Error(Unavailable("502"))))
    ->thenTodoStatus("cust-1:Stephansplatz 1, Vienna", #Pending)
  )

  // A service that cannot answer is retried, not written off as a verdict.
  test("an unreachable geocoder leaves the TODO Pending for retry", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {
      customerId: "cust-1",
      address: "Stephansplatz 1, Vienna",
    })
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("geocoder unavailable: 502")))
    ->thenTodoStatus("cust-1:Stephansplatz 1, Vienna", #Pending)
  )

  // A verdict is a success of the translation, so the row completes.
  test("no match completes the TODO with a verdict rather than retrying", () =>
    givenTodo("cust-1:nowhere at all", {customerId: "cust-1", address: "nowhere at all"})
    ->whenTranslateMocked((_id, item) =>
      Promise.resolve(
        Ok(
          Some((
            item.customerId,
            MarkAddressUnresolvable({
              address: item.address,
              reason: `no match for "${item.address}"`,
            }),
          )),
        ),
      )
    )
    ->thenTodoStatus("cust-1:nowhere at all", #Completed)
  )
})
