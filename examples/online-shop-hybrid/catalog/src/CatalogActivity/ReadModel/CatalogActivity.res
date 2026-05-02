// Catalog activity read model — a denormalised audit row per entity (category
// or product) that has changed in the catalog. Populated from BOTH the Category
// Aggregate and the Product DCB log via a multi-source mapping. See
// `CatalogActivity_Projections.res` for the mixed-source projection.

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
  kind: kind,
  lastChange: change,
}
