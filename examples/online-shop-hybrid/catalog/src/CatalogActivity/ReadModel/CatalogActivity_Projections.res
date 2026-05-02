// Catalog activity mappings: a single ReadModel fed by TWO sources — the
// Category Aggregate and the catalog plugin's DCB EventLog.
//
// The Aggregate source resolves to `Mapping.sourceName = "Category"` (the
// Aggregate Spec.name).
//
// The DCB source resolves to `Mapping.sourceName = "CatalogDcbEventLog"`,
// which is the key under which `Plugin_Builder` registers the catalog plugin's
// DCB EventTopic in `allEventTopics` AND the `meta.service` value DcbEventLog
// stamps on every published event — these two must match for the dispatch to
// route DCB events into this projection.

@@reventless.mappings

// ─────────────────────────────────────────────────────────────
// DCB source spec — `name` MUST equal `<pluginName>DcbEventLog`.
// `module Id = Reventless.Id.String` and dcbTags on `*Id` fields are
// auto-injected by `@@reventless.mappings` (Source-module scan).
//
// `event` is a typed subset of the DCB log's full event union — only the
// variants this consumer cares about. Unknown variants from sibling slices
// (e.g. `RecordProductDemand`) decode as parse errors and the mapping logs
// + falls through, identical to how Aggregate ReadModels handle event
// variants they don't enumerate.
// ─────────────────────────────────────────────────────────────

module CatalogDcbSource = {
  let name = "CatalogDcbEventLog"

  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductRenamed({productId: string, name: string})
}

// ─────────────────────────────────────────────────────────────
// Source 1 — Category Aggregate
// ─────────────────────────────────────────────────────────────

module CategoryActivityMapping = Mapping.Make(
  Category,
  CatalogActivity,
  {
    open Category
    let project = ({event, id, _}) =>
      switch event {
      | Added(_) =>
        Set(
          id,
          {
            CatalogActivity.kind: Category,
            lastChange: (Added: CatalogActivity.change),
          },
        )
      | Renamed(_) =>
        Update(id, state => {...state, lastChange: (Renamed: CatalogActivity.change)})
      | Archived =>
        Update(id, state => {...state, lastChange: (Archived: CatalogActivity.change)})
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Source 2 — Catalog DCB EventLog
// ─────────────────────────────────────────────────────────────

module ProductActivityMapping = Mapping.Make(
  CatalogDcbSource,
  CatalogActivity,
  {
    open CatalogDcbSource
    let project = ({event, _}) =>
      switch event {
      | ProductAdded({productId}) =>
        Set(productId, {CatalogActivity.kind: Product, lastChange: Added})
      | ProductRenamed({productId}) =>
        Update(productId, state => {...state, lastChange: Renamed})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CategoryActivityMapping), module(ProductActivityMapping)]
