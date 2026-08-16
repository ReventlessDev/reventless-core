// Customers read model specification.
// Query-side state for registered customers. This is a **mixed-source** read
// model: the customer profile fields come from the Customer aggregate, while
// `orderCount` is fed by the Ordering DCB log's `OrderPlaced` events (keyed by
// `customerId`). See `Customers_Projections.res` for the two source mappings.

@@reventless.spec

// Operator surface: the customer list is everyone's profile and order count, so
// it is readable by an operator only. A shopper reads their own orders instead.
@@reventless.authorize(AllowGroups(["Admin", "Fulfilment"]))

// `location` is one declared point, so the generated read-model view offers a
// map display that drops a pin per customer — from the declaration, not from a
// `lat`/`lng` name guess over the numeric fields. It is fed by the Customer
// aggregate's `LocationSet` event (see `Customers_Projections.res`), and it is
// `option` because a customer has no location until that event arrives: the
// `0.0, 0.0` this used to default to is a real coordinate in the Gulf of Guinea,
// so every unlocated customer was pinned there.
// Whether this customer's address has been turned into a point yet, and if not,
// why not. `location: option<GeoPoint.t>` alone cannot say: `None` would mean
// both "the geocoder has not run" and "the geocoder ran and failed", and an
// operator cannot act on a state that means two things.
//
// Not the record's `@lifecycle`, despite the name: no command branches on it and
// no lifecycle passes through it. It is the geocoder's progress, which is a fact
// about a background job rather than about where this customer is in their life.
// That is a distinction the annotation's old name (`@status`) made easy to miss.
@schema
type locationStatus =
  | Pending
  | Located
  | Unresolvable

// Where a customer is in their life with the shop. `Deactivated` is a state
// rather than a flag beside one, which is what lets a command say where it
// belongs: `@transition(([Deactivated]) => Active)` on `Reactivate` is the whole of
// "offer the way back on a deactivated customer and nowhere else".
//
// The alternative — an `accountStatus` enum AND a `deactivated: bool` — is the
// same fact twice, with nothing keeping the two in step.
// `@retired` sits on the state that withdraws the row. A deactivated customer is
// withdrawn from ordinary use rather than deleted: their orders still reference
// them, and an operator still needs to find them.
@schema
type accountStatus =
  | Active
  | @retired Deactivated

// A read model states its own key. Without `customerId` the only identifier on a
// row is the Relay global `id`, which resolves the row through `node` but cannot
// be compared to anything: no eq filter by customer, no sort, and no way to line
// a row up against `Orders.customerId`. Both sources below already agree on this
// key — the aggregate's instance id and the DCB event's `customerId` — so one
// field serves both. No `@id` needed: the name matches the component.
@schema
type state = {
  customerId: string,
  @displayName email: string,
  address: string,
  location: option<Reventless.GeoPoint.t>,
  locationStatus: locationStatus,
  // Why the geocoder gave up, for the rows sitting in `Unresolvable`. Absent
  // otherwise; hidden from list views because it is only meaningful on a row a
  // human is already looking into.
  @hidden locationNote: option<string>,
  // `@lifecycle` makes this the field a command's `@transition` is written in
  // terms of; the retirement is on `accountStatus`'s own constructor, so ordinary
  // reads exclude a deactivated customer with no second annotation here.
  //
  // Annotated rather than named `lifecycle`: the field is honestly called
  // `accountStatus`, which is what the annotation rung exists for.
  @lifecycle accountStatus: accountStatus,
  orderCount: int,
}
