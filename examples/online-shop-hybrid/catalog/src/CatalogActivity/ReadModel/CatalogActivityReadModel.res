// Catalog activity read model — a denormalised audit row per entity (category
// or product) that has changed in the catalog. Populated from BOTH the Category
// Aggregate and the Product DCB log via a multi-source mapping. See
// `CatalogActivityProjections.res` and Plan 03 (mixed-source ReadModel).

@@reventless.spec

@schema
type state = {
  /** "category" or "product" */
  kind: string,
  /** Last event type observed for this entity (e.g. "Added", "Renamed"). */
  lastChange: string,
}
