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
// operator cannot act on a state that means two things. Marked `@lifecycle` so
// the generated view sections and badges rows by it without further configuration.
@schema
type locationStatus =
  | Pending
  | Located
  | Unresolvable

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
  // Annotated rather than renamed: the field is honestly called `locationStatus`,
  // and calling it `lifecycle` would assert something false about it. This is the
  // case the annotation rung exists for — the convention rung only serves a record
  // whose lifecycle field can carry the name.
  @lifecycle locationStatus: locationStatus,
  // Why the geocoder gave up, for the rows sitting in `Unresolvable`. Absent
  // otherwise; hidden from list views because it is only meaningful on a row a
  // human is already looking into.
  @hidden locationNote: option<string>,
  // A deactivated customer is withdrawn from ordinary use rather than deleted:
  // their orders still reference them, and an operator still needs to find them.
  // `@retired` is what makes the platform say so — ordinary reads exclude these
  // rows, and a consumer renders the fact as a state of the record instead of as
  // a column reading `false` on nearly every row.
  @retired deactivated: bool,
  orderCount: int,
}
