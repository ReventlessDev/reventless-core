// Customer aggregate specification.
// A registered buyer with contact details and account status.

@@reventless.spec

module Id = CustomerId

// The command is where an address is first accepted, so it is where the type
// belongs — a value that reaches the log is already permanent. The events below
// stay plain `string`: they record what was accepted, and re-validating history
// on read is the risk a branded scalar exists to avoid.
@schema
type command =
  | Register({@pii email: @s.matches(Reventless.Email.schema) string, @pii address: string})
  | UpdateEmail({@pii email: @s.matches(Reventless.Email.schema) string})
  | UpdateAddress({@pii address: string})
  | Deactivate

@schema
type event =
  | Registered({@pii email: string, @pii address: string})
  | EmailUpdated({@pii email: string})
  | AddressUpdated({@pii address: string})
  | Deactivated

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated
