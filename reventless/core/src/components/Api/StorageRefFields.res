// Which fields of which committed events can hold a storage ref — read off the
// declarations rather than hand-listed.
//
// This is the deploy-time half of the claim mechanism (see
// [docs/plans/done/upload-pending-claim-and-expiry.md]). An uploaded object is minted
// carrying a "pending" tag and expires while it still has one, so something has
// to notice when an event finally references it. That something needs to know
// three things, and a `@storageRef` declaration already says all three:
//
//   which events to observe   only variants with at least one declared field
//   where the refs sit        the field name, and whether it holds one or many
//   which store they're in    the target, qualified to `{plugin}.{store}`
//
// Deriving it here rather than in the claimer means the runtime carries a flat
// lookup table and no schema machinery: the Lambda reads `{eventType → fields}`
// and never sees a sury schema. It also means an annotation added, moved or
// deleted changes what gets claimed on the next deploy, with nothing to keep in
// sync by hand.
//
// Read the same way `Plugin_Structure` reads the same declarations — top-level
// properties of each variant, via `StorageRef.getFieldStore`. A store nested
// inside an object is not provisioned there and so is not claimed here: one
// reading, consistently narrow, rather than two that could disagree about which
// fields exist.

/** One declared ref-bearing field of one event variant. */
type refField = {
  /** The field's name on the event's payload (`data` on the wire). */
  field: string,
  /** Whether the field holds one ref or an array of them. */
  arity: Reventless.StorageRef.arity,
  /** The store the refs live in, qualified `{plugin}.{store}` — already
      resolved against the declaring plugin, so a reader never has to know
      whose plugin it came from. */
  store: string,
}

/** The ref-bearing fields of one event variant. Only variants with at least
    one are produced, so an empty result means "this event log carries no
    storage refs" and the caller can skip it entirely. */
type eventRefFields = {
  eventType: string,
  fields: array<refField>,
}

// A variant is `{TAG: "<Name>", …fields}` (payload-less variants are a bare
// string const and can hold nothing, so they drop out here).
let fromVariant = (~plugin: string, variant: S.t<unknown>): option<eventRefFields> =>
  switch variant {
  | S.Object({properties}) =>
    switch properties->Dict.get("TAG") {
    | Some(String({const: ?Some(eventType)})) =>
      let fields =
        properties
        ->Dict.toArray
        ->Array.filterMap(((field, fieldSchema)) =>
          Reventless.StorageRef.getFieldStore(fieldSchema)->Option.map(((target, arity)) => {
            field,
            arity,
            // An unqualified store belongs to the declaring plugin — the same
            // resolution `Plugin_Structure` makes, so the key the claimer looks
            // up is the key the deploy provisioned.
            store: target.plugin->Option.getOr(plugin) ++ "." ++ target.store,
          })
        )
        ->Array.toSorted((a, b) => String.compare(a.field, b.field))
      fields->Array.length == 0 ? None : Some({eventType, fields})
    | _ => None
    }
  | _ => None
  }

/**
The ref-bearing fields of every variant in an event log's event schema.

`~plugin` is the registered name of the plugin the event log belongs to, used
to qualify a store the annotation left unqualified.
*/
let fromEventSchema = (~plugin: string, eventSchema: S.t<unknown>): array<eventRefFields> =>
  switch eventSchema {
  | Union({anyOf}) => anyOf->Array.filterMap(v => fromVariant(~plugin, v))
  | other => fromVariant(~plugin, other)->Option.mapOr([], e => [e])
  }

/**
The wire form the claimer reads: `{"<eventType>": [{"field", "arity", "store"}]}`.

A flat JSON object rather than a schema, because it crosses into a Lambda's
environment: the runtime side does a dictionary lookup and a field read, and
carries no sury dependency to do it.
*/
let toJson = (entries: array<eventRefFields>): JSON.t =>
  entries
  ->Array.map(({eventType, fields}) => (
    eventType,
    fields
    ->Array.map(({field, arity, store}) =>
      Dict.fromArray([
        ("field", JSON.Encode.string(field)),
        (
          "arity",
          JSON.Encode.string(
            switch arity {
            | Single => "one"
            | Multiple => "many"
            },
          ),
        ),
        ("store", JSON.Encode.string(store)),
      ])->JSON.Encode.object
    )
    ->JSON.Encode.array,
  ))
  ->Dict.fromArray
  ->JSON.Encode.object

/** The distinct stores an event log's declarations point at. What the claimer's
    IAM has to cover for that log, and what a coverage check compares against
    the set of stores the deploy actually provisioned. */
let storesOf = (entries: array<eventRefFields>): array<string> =>
  entries
  ->Array.flatMap(({fields}) => fields->Array.map(({store}) => store))
  ->Belt.Set.String.fromArray
  ->Belt.Set.String.toArray
