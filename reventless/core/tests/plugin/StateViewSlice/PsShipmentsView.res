// Test fixture spec for the @transition cross-check.
// A view that declares a lifecycle, so a command's declared states have
// something to be checked against. `PsOrdersView` deliberately declares none —
// the two together cover both the checked and the unvalidated path.

@@reventless.spec("Shipments")

@schema
type consumedEvent =
  | ShipmentBooked({shipmentId: string})
  | ShipmentDispatched({shipmentId: string})

@schema
type shipmentStatus =
  | Booked
  | Dispatched

@schema
type state = {shipmentId: string, @lifecycle shipmentStatus: shipmentStatus}

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | ShipmentBooked({shipmentId}) => [Set(shipmentId, {shipmentId, shipmentStatus: Booked})]
  | ShipmentDispatched({shipmentId}) =>
    [Update(shipmentId, s => {...s, shipmentStatus: Dispatched})]
  }
