// CategoryActivity mappings: a single ReadModel fed by TWO DCB source views of
// the catalog plugin's shared DCB EventLog.
//
// `Mapping.sourceName` MUST equal `<pluginName>DcbEventLog` for both sources
// (this is the key under which `Plugin_Builder` registers the catalog plugin's
// DCB EventTopic AND the `meta.service` value DcbEventLog stamps on every
// published event). Multiple Mappings with the same `sourceName` is the
// canonical DCB-pure multi-source pattern: each Mapping carves a typed subset
// of the full DCB event union and projects into a different shape of the
// shared ReadModel state.

@@reventless.mappings

// ─────────────────────────────────────────────────────────────
// DCB source view 1 — Category-side events
// ─────────────────────────────────────────────────────────────

module CategoryEvents = {
  let name = "CatalogDcbEventLog"

  @schema
  type event =
    | CategoryAdded({categoryId: string, name: string})
    | CategoryRenamed({categoryId: string, name: string})
    | CategoryArchived({categoryId: string})
}

// ─────────────────────────────────────────────────────────────
// DCB source view 2 — Product-side events
// ─────────────────────────────────────────────────────────────

module ProductEvents = {
  let name = "CatalogDcbEventLog"

  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductNameChanged({productId: string, name: string})
}

// ─────────────────────────────────────────────────────────────
// Mapping 1 — Category source view
// ─────────────────────────────────────────────────────────────

module CategoryActivityMapping = Mapping.Make(
  CategoryEvents,
  CategoryActivity,
  {
    open CategoryEvents
    let project = ({event, _}) =>
      switch event {
      | CategoryAdded({categoryId, name}) =>
        Set(
          categoryId,
          {
            CategoryActivity.name: name,
            kind: Category,
            lastChange: (Added: CategoryActivity.change),
          },
        )
      | CategoryRenamed({categoryId, name}) =>
        Update(categoryId, state => {
          ...state,
          name,
          lastChange: (Renamed: CategoryActivity.change),
        })
      | CategoryArchived({categoryId}) =>
        Update(categoryId, state => {...state, lastChange: (Archived: CategoryActivity.change)})
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Mapping 2 — Product source view
// ─────────────────────────────────────────────────────────────

module ProductActivityMapping = Mapping.Make(
  ProductEvents,
  CategoryActivity,
  {
    open ProductEvents
    let project = ({event, _}) =>
      switch event {
      | ProductAdded({productId, name}) =>
        Set(productId, {CategoryActivity.name: name, kind: Product, lastChange: Added})
      | ProductNameChanged({productId, name}) =>
        Update(productId, state => {...state, name, lastChange: Renamed})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CategoryActivityMapping), module(ProductActivityMapping)]
