// Customer aggregate specification.
// A registered buyer with contact details and account status.

@@reventless.spec

// The command is where an address is first accepted, so it is where the type
// belongs — a value that reaches the log is already permanent. The events below
// stay plain `string`: they record what was accepted, and re-validating history
// on read is the risk a branded scalar exists to avoid.
@schema
type command =
  | Register({email: @s.matches(Reventless.Email.schema) string, address: string})
  | UpdateEmail({email: @s.matches(Reventless.Email.schema) string})
  | UpdateAddress({address: string})
  | Deactivate

@schema
type event =
  | Registered({email: string, address: string})
  | EmailUpdated({email: string})
  | AddressUpdated({address: string})
  | Deactivated

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated
