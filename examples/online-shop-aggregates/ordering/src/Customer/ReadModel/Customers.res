// Customers read model specification.
// Query-side state for registered customers.

@@reventless.spec

// Marked on the query side too, where it is what makes the field render as a
// mailto link instead of a text box: the AutoUI reads the semantic off this
// state schema, not off the command's.
@schema
type state = {
  email: @s.matches(Reventless.Email.schema) string,
  address: string,
  deactivated: bool,
}

