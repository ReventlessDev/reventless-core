// The first outbound translation slice fed by an **Aggregate** rather than a DCB
// event log, which is what makes `~sourceId` load-bearing here: a DCB event names
// its own subject in the payload, an aggregate's does not, because the aggregate
// id is what addressed it in the first place.
//
// `OutboundTranslation_GWT.Make` expects a single SliceSpec with `collect` at the
// top level. Compose it on locally — the real `translate` reaches a geocoder, and
// is mocked at test time via `whenTranslateMocked`.

module GeocodeCustomerAddressSlice = {
  include GeocodeCustomerAddress
  let collect = GeocodeCustomerAddress_Translation.collect
}

@@reventless.gwt

let vienna: Reventless.GeoPoint.t = {lat: 48.2082, lng: 16.3738}

describe("GeocodeCustomerAddress OutboundTranslationSlice", () => {
  // The capability this slice exists to prove: the customer id arrives from the
  // event envelope, not the payload. Without it the outbound item could not name
  // the customer it is for.
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

  // Keyed by customer *and* address on purpose. Phase 1 skips an id it has
  // already seen, so keying by customer alone would make a corrected address
  // look like work already done and it would never be geocoded.
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

  // The distinction the whole design turns on: a service that cannot answer is
  // retried, so the row stays Pending rather than being written off.
  test("an unreachable geocoder leaves the TODO Pending for retry", () =>
    givenTodo("cust-1:Stephansplatz 1, Vienna", {
      customerId: "cust-1",
      address: "Stephansplatz 1, Vienna",
    })
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("geocoder unavailable: 502")))
    ->thenTodoStatus("cust-1:Stephansplatz 1, Vienna", #Pending)
  )

  // A verdict is a *success* of the translation, so the row completes rather
  // than retrying a permanently bad address forever.
  test("no match completes the TODO with a verdict rather than retrying", () =>
    givenTodo("cust-1:nowhere at all", {customerId: "cust-1", address: "nowhere at all"})
    ->whenTranslateMocked((_id, item) =>
      Promise.resolve(
        Ok(
          Some((
            item.customerId,
            MarkAddressUnresolvable({address: item.address, reason: "no match for this address"}),
          )),
        ),
      )
    )
    ->thenTodoStatus("cust-1:nowhere at all", #Completed)
  )
})
