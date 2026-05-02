// Catalog activity mappings: a single ReadModel fed by TWO sources — the
// Category Aggregate and the catalog plugin's DCB EventLog. Demonstrates the
// mixed-source pattern enabled by Plan 03.
//
// The Aggregate source resolves to `Mapping.sourceName = "Category"` (the
// Aggregate Spec.name).
//
// The DCB source resolves to `Mapping.sourceName = "CatalogDcbEventLog"`,
// which is the key under which `Plugin_Builder` registers the catalog plugin's
// DCB EventTopic in `allEventTopics` AND the `meta.service` value DcbEventLog
// stamps on every published event. See Plan 03 / Phase 1.5 for why these two
// must match.

open Reventless.Message
open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// DCB source spec — `name` MUST equal `<pluginName>DcbEventLog`.
// Hand-rolled `Source`-shaped module (the canonical pattern for DCB sources;
// `Reventless.Projection.DcbSource.Make` is also available).
//
// `event` is a typed subset of the DCB log's full event union — only the
// variants this consumer cares about. Unknown variants from sibling slices
// (e.g. `RecordProductDemand`) decode as parse errors and the mapping logs
// + falls through, identical to how Aggregate ReadModels handle event
// variants they don't enumerate.
// ─────────────────────────────────────────────────────────────

module CatalogDcbSource = {
  module Id = Reventless.Id.String
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
  CatalogActivityReadModel,
  {
    open Category
    let project = ({event, id, _}) =>
      switch event {
      | Added(_) =>
        Set(
          id,
          {
            CatalogActivityReadModel.kind: Category,
            lastChange: (Added: CatalogActivityReadModel.change),
          },
        )
      | Renamed(_) =>
        Update(id, state => {...state, lastChange: (Renamed: CatalogActivityReadModel.change)})
      | Archived =>
        Update(id, state => {...state, lastChange: (Archived: CatalogActivityReadModel.change)})
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Source 2 — Catalog DCB EventLog
// ─────────────────────────────────────────────────────────────

module ProductActivityMapping = Mapping.Make(
  CatalogDcbSource,
  CatalogActivityReadModel,
  {
    open CatalogDcbSource
    let project = ({event, _}) =>
      switch event {
      | ProductAdded({productId}) =>
        Set(productId, {CatalogActivityReadModel.kind: Product, lastChange: Added})
      | ProductRenamed({productId}) =>
        Update(productId, state => {...state, lastChange: Renamed})
      }
  },
)
