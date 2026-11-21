// A customer's address is located: the way out that geocodes it is fed by the
// customer aggregate, whose events do not name their own subject, so the work it
// queues is keyed by the id the event was recorded under. The geocoder is a fake;
// what it answers becomes the command the customer decides.
@@reventless.gwt

open Ordering_Examples

let vienna: Reventless.GeoPoint.t = {lat: 48.2082, lng: 16.3738}

describe("Customer flow — register → geocode → located", () => {
  // scenario-id: c84d8f8e-32bb-4d94-b989-0df1d680c46c
  test(
    "a registered address is geocoded under the customer's id, and its location recorded",
    ~tells="A customer's address is located",
    () =>
      start
      ->Flow.Customer.whenCommand(
        ~id=cust1,
        Customer.Register({email: aliceEmail, address: viennaAddress}),
      )
      ->Flow.Customer.thenEvent(
        Customer.Registered({email: Value(aliceEmail), address: Value(viennaAddress)}),
      )
      // Queued under the customer's id, which the event does not name.
      ->Flow.GeocodeCustomerAddress.thenOutbound([
        (`${cust1}:${viennaAddress}`, {customerId: cust1, address: viennaAddress}),
      ])
      ->Flow.GeocodeCustomerAddress.whenSent(
        ~fakes=Fakes.make(
          ~geocode=async (~text as _) => Ok([
            {label: viennaAddress, point: vienna, relevance: 0.995},
          ]),
          (),
        ),
      )
      ->Flow.GeocodeCustomerAddress.thenSent([Fakes.Geocoded({text: viennaAddress})])
      ->Flow.GeocodeCustomerAddress.thenIssuesCommand(
        SetLocation({location: vienna, resolvedFrom: viennaAddress}),
      )
      ->Flow.Customer.whenIssued(~id=cust1)
      ->Flow.Customer.thenEvent(
        Customer.LocationSet({location: vienna, resolvedFrom: Value(viennaAddress)}),
      ),
  )
})
