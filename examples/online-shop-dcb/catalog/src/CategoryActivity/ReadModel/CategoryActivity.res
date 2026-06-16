// Catalog activity read model — a denormalised audit row per entity (category
// or product) that has changed in the catalog. Populated from TWO views of the
// shared catalog DCB EventLog: Category-side events and Product-side events.
// See `CategoryActivity_Projections.res` for the multi-source mapping. The
// example stays DCB-pure: both sources resolve to the same DCB EventLog name.

@@reventless.spec

@schema
type kind =
  | Category
  | Product

@schema
type change =
  | Added
  | Renamed
  | Archived

@schema
type state = {
  name: string,
  kind: kind,
  lastChange: change,
}
