// Fixture for the field markers that meet a branded semantic type. A spec file
// and named `*ReadModel*` deliberately: the annotation machinery runs only under
// `@@reventless.spec` and only for a file the PPX reads as a read model or state
// view, so a module inside the test would exercise nothing.
//
// The two markers here are the two that used to read the literal `string`
// keyword and so refuse a field whose type is a string wearing a brand.

@@reventless.spec("BrandedMarkersReadModel")

@schema
type consumedEvent = SubscriptionOpened({subscriptionId: string, email: string})

@schema
type state = {
  @id subscriptionId: string,
  // The owner named by an address rather than by a bare id. `@owner` has to
  // compose onto the schema sury-ppx derives from `Email.t` — replacing it would
  // type-check and leave the field a plain marked string.
  @owner email: Reventless.Email.t,
  // `@displayName` never touches the field's schema; it only joins values, so a
  // branded string is one it can read.
  @displayName @summary openedAt: Reventless.DateTime.t,
}
