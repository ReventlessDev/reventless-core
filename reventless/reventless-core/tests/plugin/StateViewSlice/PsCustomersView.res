// Test fixture for Phase 3 labelField extraction.
// Uses composite @displayName on firstName + lastName to exercise the
// DisplayName spec path of labelFieldsFromStateSchema.

@@reventless.spec("Customers")

@schema
type consumedEvent =
  | CustomerAdded({customerId: string, firstName: string, lastName: string})

@schema
type state = {
  customerId: string,
  @displayName firstName: string,
  @displayName lastName: string,
}

let project = event =>
  switch event {
  | CustomerAdded({customerId, firstName, lastName}) =>
    [Set(customerId, {customerId, firstName, lastName})]
  }
