// Mixed-source read model: profile fields from the Customer aggregate,
// `orderCount` from the Ordering DCB log. Mappings in `Customers_Projections.res`.

@@reventless.spec

// Operator surface: everyone's profile, so operator-only. A shopper reads their
// own orders instead.
@@reventless.authorize(AllowGroups(["Admin", "Fulfilment"]))

// A state rather than a flag beside one, so a command can say where it belongs:
// `Moves([Deactivated], Active)` on `Reactivate`. `@retired` withdraws
// the row from ordinary reads without deleting it.
@schema
type accountStatus =
  | Active
  | @retired Deactivated

// `customerId` is declared so the row is filterable and joinable against
// `Orders.customerId`; the Relay global `id` alone is not comparable. No `@id`
// needed — the name matches the component.
@schema
type state = {
  customerId: string,
  @displayName email: string,
  address: string,
  // The map pin is drawn from the `Located` arm's declared point. Not the
  // record's `@lifecycle` — no command branches on it; `accountStatus` is that.
  geolocation: Reventless.Geolocation.t,
  // Annotated rather than named `lifecycle`, which is what the annotation is for.
  @lifecycle accountStatus: accountStatus,
  orderCount: int,
}
