// --- Tag types ---

/**
A key-value tag attached to a DCB event for content-based filtering.

Tags are extracted from `@s.matches(DcbTag.string)` or `@s.matches(DcbTag.int)`
annotated fields in an event's schema. The `key` is the field name and the
`value` is the serialized field value.

@example
```rescript
// CatalogEventLog.res
@schema type event =
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
// Produces tag: {key: "categoryId", value: "cat-1"}
```
*/
type tag = {key: string, value: string}

/**
A single clause in a DCB event query.

Combines an optional list of event type names with optional tags.
An event matches a `queryItem` if it matches ALL specified tags AND
its type is in the `eventTypes` list (or the list is absent).
*/
type queryItem = {
  eventTypes?: array<string>,
  tags?: array<tag>,
}

/**
A DCB event log query — an array of `queryItem` clauses.

An event matches the query if it satisfies ANY of the clauses (OR semantics
across clauses, AND semantics within a clause).

@example
```rescript
// Read CategoryAdded and CategoryArchived events for category "cat-1"
let q: DcbTag.query = [
  {
    eventTypes: ["CategoryAdded", "CategoryArchived"],
    tags: [{key: "categoryId", value: "cat-1"}],
  }
]
```
*/
type query = array<queryItem>

/**
An opaque string that identifies a position in the DCB event log sequence.
Returned by `append` and accepted by `read` / `readStream` as the `~after` cursor.
*/
type sequencePosition = string

/**
An optimistic-concurrency condition for a DCB `append` operation.

The append succeeds only if the events matching `query` have not changed
since the position `after`. Omit `after` to assert "no matching events exist yet".

@example
```rescript
// Append only if no CategoryAdded events for "cat-1" exist yet
let condition: DcbTag.appendCondition = {
  query: [{
    eventTypes: ["CategoryAdded"],
    tags: [{key: "categoryId", value: "cat-1"}],
  }],
}
```
*/
type appendCondition = {
  query: query,
  after?: sequencePosition,
}

// --- Sury metadata for tag annotation ---

/** Internal sury metadata ID used to mark DCB-tagged schema fields. */
let dcbTagId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="dcb", ~name="tag")

/**
A sury string schema annotated as a DCB tag field.

Use with `@s.matches(DcbTag.string)` on event record fields that should
be extracted as content-based routing tags.

@example
```rescript
// CatalogEventLog.res
@schema type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, price: float})
```
*/
let string: S.t<string> = S.string->S.Metadata.set(~id=dcbTagId, true)

/**
A sury int schema annotated as a DCB tag field.
Use with `@s.matches(DcbTag.int)` on integer fields that should be extracted as tags.
*/
let int: S.t<int> = S.int->S.Metadata.set(~id=dcbTagId, true)

// --- Tag extraction from sury schemas ---

external toUnknownSchema: S.t<'a> => S.t<unknown> = "%identity"

/** Returns `true` if the schema was annotated with `DcbTag.string` or `DcbTag.int`. */
let isTagged = (fieldSchema: S.t<unknown>) =>
  S.Metadata.get(fieldSchema, ~id=dcbTagId)->Option.isSome

/** Converts a JSON value to its string representation for use as a tag value. */
let jsonValueToString = json =>
  switch json {
  | JSON.String(s) => s
  | JSON.Number(n) => n->Float.toString
  | JSON.Boolean(b) => b ? "true" : "false"
  | _ => json->JSON.stringify
  }

/**
Extracts tags from a flat JSON object given a map of field schemas.
Only fields whose schema is tagged (via `DcbTag.string` / `DcbTag.int`) are extracted.
*/
let extractTagsFromProperties = (properties: dict<S.t<unknown>>, jsonDict: dict<JSON.t>) =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((fieldName, fieldSchema)) =>
    if isTagged(fieldSchema) {
      jsonDict
      ->Dict.get(fieldName)
      ->Option.map(jsonValue => {key: fieldName, value: jsonValue->jsonValueToString})
    } else {
      None
    }
  )

/**
Extracts DCB tags from an event JSON value using the event's sury schema.

Supports both union (variant) types and plain object types. For variant types
only the fields of the matching variant branch are inspected.
*/
let extractTagsFromJson = (schema: S.t<unknown>, json: JSON.t): array<tag> =>
  switch schema {
  | Union({anyOf}) =>
    switch json->JSON.Decode.object {
    | Some(jsonDict) =>
      let jsonTag = jsonDict->Dict.get("TAG")->Option.flatMap(j =>
        switch j {
        | JSON.String(s) => Some(s)
        | _ => None
        }
      )
      anyOf->Array.reduce([], (acc, variantSchema) =>
        if acc->Array.length > 0 {
          acc
        } else {
          switch variantSchema {
          | Object({items, properties}) =>
            let variantTag = items
              ->Array.find(item => item.location == "TAG")
              ->Option.flatMap(item =>
                switch item.schema {
                | String({const}) => Some(const)
                | _ => None
                }
              )
            if variantTag == jsonTag {
              extractTagsFromProperties(properties, jsonDict)
            } else {
              []
            }
          | _ => []
          }
        }
      )
    | None => []
    }
  | Object({properties}) =>
    switch json->JSON.Decode.object {
    | Some(jsonDict) => extractTagsFromProperties(properties, jsonDict)
    | None => []
    }
  | _ => []
  }

/**
Extracts DCB tags from a typed event value using its sury schema.

Serializes the value to JSON first, then delegates to `extractTagsFromJson`.

@example
```rescript
let tags = DcbTag.extractTags(
  CatalogEventLog.eventSchema,
  CategoryAdded({categoryId: "cat-1", name: "Electronics"}),
)
// [{key: "categoryId", value: "cat-1"}]
```
*/
let extractTags = (schema: S.t<'a>, value: 'a): array<tag> => {
  let json = value->S.reverseConvertToJsonOrThrow(schema)
  extractTagsFromJson(schema->toUnknownSchema, json)
}

// --- Extract event type names from event schema ---
// For a variant type like `type event = ItemCreated({...}) | ItemRenamed({...})`,
// this extracts ["ItemCreated", "ItemRenamed"]

/**
Extracts all variant constructor names from an event schema.

For `CatalogEventLog.event` returns
`["ProductAdded", "ProductNameUpdated", ..., "CategoryAdded", ...]`.
Used by the DCB runtime to build `queryItem.eventTypes` arrays automatically.
*/
let extractEventTypes = (schema: S.t<'event>): array<string> => {
  let unknownSchema: S.t<unknown> = schema->Obj.magic
  switch unknownSchema {
  | Union({anyOf}) =>
    anyOf->Array.filterMap(variantSchema =>
      switch variantSchema {
      | Object({items}) =>
        items
        ->Array.find(item => item.location == "TAG")
        ->Option.flatMap(item =>
          switch item.schema {
          | String({const}) => Some(const)
          | _ => None
          }
        )
      | _ => None
      }
    )
  | Object({items}) =>
    items
    ->Array.find(item => item.location == "TAG")
    ->Option.flatMap(item =>
      switch item.schema {
      | String({const}) => Some([const])
      | _ => None
      }
    )
    ->Option.getOr([])
  | _ => []
  }
}

// --- Extract tagged field names from event schema ---

/**
Extracts the names of all DCB-tagged fields across all variants of an event schema.

Returns a sorted, deduplicated list of field names annotated with
`@s.matches(DcbTag.string)` or `@s.matches(DcbTag.int)`.

For `CatalogEventLog.event` returns `["categoryId", "productId"]`.
*/
let extractTaggedFields = (schema: S.t<'event>): array<string> => {
  // Convert to unknown schema for introspection
  let unknownSchema: S.t<unknown> = schema->Obj.magic

  switch unknownSchema {
  | Union({anyOf}) =>
    // For union types, collect tagged fields from all variants
    let allFields = anyOf->Array.flatMap(variantSchema =>
      switch variantSchema {
      | Object({properties}) =>
        properties
        ->Dict.toArray
        ->Array.filterMap(((fieldName, fieldSchema)) =>
          if isTagged(fieldSchema) {
            Some(fieldName)
          } else {
            None
          }
        )
      | _ => []
      }
    )
    // Deduplicate field names using Set
    let fieldSet = Set.make()
    allFields->Array.forEach(field => fieldSet->Set.add(field))
    Array.fromIterator(fieldSet->Set.values)->Array.toSorted((a, b) => String.compare(a, b))

  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((fieldName, fieldSchema)) =>
      if isTagged(fieldSchema) {
        Some(fieldName)
      } else {
        None
      }
    )
    ->Array.toSorted((a, b) => String.compare(a, b))

  | _ => []
  }
}
