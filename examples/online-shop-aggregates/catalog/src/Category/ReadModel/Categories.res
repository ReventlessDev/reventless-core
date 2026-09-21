// Categories read model specification.
// Query-side state for product categories.

@@reventless.spec

module Id = CategoryId

@schema
type state = {
  name: string,
  archived: bool,
}
