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

Use with `@s.matches(DcbTag.string)` on event and command record fields that
should be extracted as content-based routing tags. Works on both scalar fields
and array element types.

@example
```rescript
// Scalar tag (single-entity query)
@schema type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, price: float})

// Array tag (cross-entity query — automatic per-element OR clauses)
@schema type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      productId: array<@s.matches(DcbTag.string) string>,
    })
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

/**
Returns `true` if the schema is an array whose item schema is DCB-tagged.
Used by `extractTagsFromPropertiesExpanded` to detect `array<@s.matches(DcbTag.string) string>`.
*/
let isTaggedArray = (fieldSchema: S.t<unknown>) =>
  switch fieldSchema {
  | Array({additionalItems: Schema(itemSchema)}) => isTagged(itemSchema)
  | _ => false
  }

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
  switch schema->toUnknownSchema {
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

// --- Array-expanded tag extraction ---

/**
Extracts tags from a flat JSON object, expanding array values into per-element tags.

For scalar tagged fields, behaves identically to `extractTagsFromProperties`.
For array tagged fields, produces one tag per element:
`productIds: ["p1", "p2"]` → `[{key: "productIds", value: "p1"}, {key: "productIds", value: "p2"}]`
*/
let extractTagsFromPropertiesExpanded = (
  properties: dict<S.t<unknown>>,
  jsonDict: dict<JSON.t>,
) =>
  properties
  ->Dict.toArray
  ->Array.flatMap(((fieldName, fieldSchema)) =>
    if isTagged(fieldSchema) {
      switch jsonDict->Dict.get(fieldName) {
      | Some(jsonValue) => [{key: fieldName, value: jsonValue->jsonValueToString}]
      | None => []
      }
    } else if isTaggedArray(fieldSchema) {
      switch jsonDict->Dict.get(fieldName) {
      | Some(JSON.Array(elements)) =>
        elements->Array.map(element => {key: fieldName, value: element->jsonValueToString})
      | _ => []
      }
    } else {
      []
    }
  )

/**
Extracts DCB tags from an event JSON value, expanding array values into per-element tags.

Like `extractTagsFromJson` but array tagged fields produce one tag per element
instead of a single tag with the stringified array.
*/
let extractTagsFromJsonExpanded = (schema: S.t<unknown>, json: JSON.t): array<tag> =>
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
              extractTagsFromPropertiesExpanded(properties, jsonDict)
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
    | Some(jsonDict) => extractTagsFromPropertiesExpanded(properties, jsonDict)
    | None => []
    }
  | _ => []
  }

/**
Extracts DCB tags from a typed value, expanding array tagged fields into per-element tags.

@example
```rescript
let tags = DcbTag.extractTagsExpanded(
  PlaceOrder.commandSchema,
  PlaceOrder({orderId: "ord-1", customerId: "c1", productIds: ["p1", "p2"]}),
)
// [{key: "orderId", value: "ord-1"}, {key: "productIds", value: "p1"}, {key: "productIds", value: "p2"}]
```
*/
let extractTagsExpanded = (schema: S.t<'a>, value: 'a): array<tag> => {
  let json = value->S.reverseConvertToJsonOrThrow(schema)
  extractTagsFromJsonExpanded(schema->toUnknownSchema, json)
}

// --- Automatic query construction from command schema ---

/**
Returns `true` if any field in the schema is a tagged array
(`array<@s.matches(DcbTag.string) string>`).
Used to automatically determine whether to build single-clause or multi-clause queries.
*/
let hasTaggedArrayFields = (schema: S.t<'a>): bool =>
  switch schema->toUnknownSchema {
  | Union({anyOf}) =>
    anyOf->Array.some(variantSchema =>
      switch variantSchema {
      | Object({properties}) =>
        properties->Dict.toArray->Array.some(((_, fieldSchema)) => isTaggedArray(fieldSchema))
      | _ => false
      }
    )
  | Object({properties}) =>
    properties->Dict.toArray->Array.some(((_, fieldSchema)) => isTaggedArray(fieldSchema))
  | _ => false
  }

/**
Builds a DCB query from a command value and its schema.

Automatically detects the query mode from the schema:
- If the schema has tagged array fields → cross-entity mode: each tag becomes
  its own OR clause (per-element expansion for arrays).
- Otherwise → single-entity mode: all tags go into one AND clause.

@example
```rescript
// Single-entity command → single AND clause
let query = DcbTag.buildQueryFromCommand(
  ~eventTypes=["ItemCreated"],
  ~schema=CreateItem.commandSchema,
  ~value=CreateItem({itemId: "item-1", name: "Test"}),
)
// [{eventTypes: ["ItemCreated"], tags: [{key: "itemId", value: "item-1"}]}]

// Cross-entity command → per-element OR clauses
let query = DcbTag.buildQueryFromCommand(
  ~eventTypes=["OrderPlaced", "CatalogProductSynced"],
  ~schema=PlaceOrder.commandSchema,
  ~value=PlaceOrder({orderId: "ord-1", customerId: "c1", productId: ["p1", "p2"]}),
)
// [{eventTypes: [...], tags: [{key: "orderId", value: "ord-1"}]},
//  {eventTypes: [...], tags: [{key: "productId", value: "p1"}]},
//  {eventTypes: [...], tags: [{key: "productId", value: "p2"}]}]
```
*/
let buildQueryFromCommand = (~eventTypes, ~schema: S.t<'a>, ~value: 'a): query => {
  if hasTaggedArrayFields(schema) {
    let tags = extractTagsExpanded(schema, value)
    tags->Array.map(tag => {eventTypes, tags: [{key: tag.key, value: tag.value}]})
  } else {
    let tags = extractTags(schema, value)
    [{eventTypes, tags}]
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
  switch schema->toUnknownSchema {
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
