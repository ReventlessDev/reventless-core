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
@schema
type tag = {key: string, value: string}

/**
Identifies which tag field is used as the storage partition key.
The partition key determines how events are distributed across DynamoDB partitions.
*/
@schema
type partitionTag = {key: string}

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

/** Internal sury metadata ID used to mark the partition tag field. */
let dcbPartitionTagId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="dcb", ~name="partitionTag")

/**
Internal sury metadata ID marking a tag field as *cross-partition* — readable
across every partition that carries it (a secondary-tag read), not just the
partition it is the partition key of. Opt-in; absence = the default
partition-scoped behaviour. The scope is a property of the tag *key* and must
agree across every event type that carries it (the fence-scope half depends on
it). See `docs/analysis/dcb-consistency-check-issues.md` Issue 13.
*/
let dcbCrossPartitionId: S.Metadata.Id.t<bool> =
  S.Metadata.Id.make(~namespace="dcb", ~name="crossPartition")

/** Metadata value for a composite partition member field. */
type compositePartitionMemberMeta = {position: int, sep: string}

/** Internal sury metadata ID used to mark a composite partition member field. */
let dcbCompositePartitionMemberId: S.Metadata.Id.t<compositePartitionMemberMeta> =
  S.Metadata.Id.make(~namespace="dcb", ~name="compositePartitionMember")

/**
Internal sury metadata ID carrying an explicit tag-key override. When present,
tag extraction uses the stored string as the tag `key` instead of the field name.
*/
let dcbTagKeyOverrideId: S.Metadata.Id.t<string> =
  S.Metadata.Id.make(~namespace="dcb", ~name="tagKeyOverride")

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
A sury string schema annotated as a DCB tag field with an explicit tag-key override.

Use when a field's record name differs from the desired tag key — for example,
plural-named multi-value fields whose elements should still be stored under the
singular tag key shared with single-value producers.

The PPX emits this constructor automatically for `*Ids: array<string>` fields
(stripping the trailing `s` to derive the key) and for `@dcbTag("explicitKey")`
annotations carrying a string payload.

@example
```rescript
@schema type event =
  OrderPlaced({
    orderId: string,
    productIds: array<@s.matches(DcbTag.stringForKey(~key="productId")) string>,
  })
// productIds: ["p1", "p2"] → tags [{key: "productId", value: "p1"}, {key: "productId", value: "p2"}]
```
*/
let stringForKey = (~key: string): S.t<string> =>
  S.string->S.Metadata.set(~id=dcbTagId, true)->S.Metadata.set(~id=dcbTagKeyOverrideId, key)

/**
A sury int schema annotated as a DCB tag field.
Use with `@s.matches(DcbTag.int)` on integer fields that should be extracted as tags.
*/
let int: S.t<int> = S.int->S.Metadata.set(~id=dcbTagId, true)

/**
A sury string schema annotated as both a DCB tag field AND the partition key.

Use with `@s.matches(DcbTag.partition)` on the field whose value should become
the DynamoDB partition key. Required when a DCB spec has multiple tagged fields;
optional (auto-selected) when only one tagged field exists.

@example
```rescript
@schema type event =
  | OrderPlaced({
      orderId: @s.matches(DcbTag.partition) string,
      customerId: @s.matches(DcbTag.string) string,
    })
```
*/
let partition: S.t<string> =
  S.string->S.Metadata.set(~id=dcbTagId, true)->S.Metadata.set(~id=dcbPartitionTagId, true)

/**
A sury string schema annotated as a DCB tag field with *cross-partition* read
scope.

Use via the `@crossPartition` PPX field annotation (mirroring `@partitionTag` —
no arguments). A single-tag decision read of such a tag routes to the per-tag
`tag_<key>` GSI so it returns every event carrying the tag across *all*
partitions (a secondary-tag read), and the tag's consistency fence is bumped by
*every* carrier (primary or secondary) so optimistic concurrency catches a
concurrent secondary-tag writer. The default (un-annotated) scope stays
partition-scoped. The canonical use is an M:N invariant where the event ties two
entities but can be partitioned by only one (course-subscription capacity,
"≤ N orders per product", reservations).

@example
```rescript
@schema type event =
  | StudentSubscribed({
      courseId: @s.matches(DcbTag.partition) string,
      studentId: @s.matches(DcbTag.crossPartition) string,
    })
```
*/
let crossPartition: S.t<string> =
  S.string->S.Metadata.set(~id=dcbTagId, true)->S.Metadata.set(~id=dcbCrossPartitionId, true)

/**
A sury string schema marking a field as a composite partition key member.

Use via the `@compositePartitionTag` PPX annotation. The annotation injects
`@s.matches(DcbTag.compositePartitionMember(~position=N, ~sep="S"))` automatically.
Each such field is also a regular DCB tag (individually queryable).

@param position Zero-based index of this field in the composite key construction order.
@param sep Separator placed after this field's value (ignored on the last field).
*/
let compositePartitionMember = (~position: int, ~sep: string="/"): S.t<string> =>
  S.string
  ->S.Metadata.set(~id=dcbTagId, true)
  ->S.Metadata.set(~id=dcbCompositePartitionMemberId, {position, sep})

/** Returns `true` if the schema was annotated as a composite partition member. */
let isCompositePartitionMember = (fieldSchema: S.t<unknown>): bool =>
  S.Metadata.get(fieldSchema, ~id=dcbCompositePartitionMemberId)->Option.isSome

/**
Composite partition key specification — the ordered field names and inter-field separators.
`seps[i]` is placed between `keys[i]` and `keys[i+1]`; length is always `keys.length - 1`.
*/
@schema
type compositePartitionSpec = {
  keys: array<string>,
  seps: array<string>,
}

// Republish note: alpha.65 shipped a stale compiled interface that omitted the
// @schema-generated `derivedPartitionTagSchema`, breaking downstream
// `Reventless.DcbTag.derivedPartitionTagSchema` references (e.g. reventless-aws
// PgChangeFeedRelay). This forces a clean rebuild + republish.
/** Union of simple and composite partition tag strategies. */
@schema
type derivedPartitionTag =
  | Simple(partitionTag)
  | Composite(compositePartitionSpec)

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

/** Returns `true` if the schema was annotated with `DcbTag.partition`. */
let isPartitionTag = (fieldSchema: S.t<unknown>) =>
  S.Metadata.get(fieldSchema, ~id=dcbPartitionTagId)->Option.isSome

/** Returns `true` if the schema was annotated with `DcbTag.crossPartition`. */
let isCrossPartitionTag = (fieldSchema: S.t<unknown>) =>
  S.Metadata.get(fieldSchema, ~id=dcbCrossPartitionId)->Option.isSome

/**
Returns `true` if the schema is an array whose item schema is a cross-partition
DCB tag (`array<@s.matches(DcbTag.crossPartition) string>`).
*/
let isCrossPartitionTaggedArray = (fieldSchema: S.t<unknown>) =>
  switch fieldSchema {
  | Array({additionalItems: Schema(itemSchema)}) => isCrossPartitionTag(itemSchema)
  | _ => false
  }

/**
Resolves the tag key for a scalar tagged field: the explicit override metadata if
present, otherwise the field name.
*/
let resolveTagKey = (fieldName: string, fieldSchema: S.t<unknown>): string =>
  S.Metadata.get(fieldSchema, ~id=dcbTagKeyOverrideId)->Option.getOr(fieldName)

/**
Resolves the tag key for an array tagged field. The override metadata sits on the
inner element schema; falls back to the field name when no override is set.
*/
let resolveArrayTagKey = (fieldName: string, fieldSchema: S.t<unknown>): string =>
  switch fieldSchema {
  | Array({additionalItems: Schema(itemSchema)}) =>
    S.Metadata.get(itemSchema, ~id=dcbTagKeyOverrideId)->Option.getOr(fieldName)
  | _ => fieldName
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
      ->Option.map(jsonValue => {
        key: resolveTagKey(fieldName, fieldSchema),
        value: jsonValue->jsonValueToString,
      })
    } else {
      None
    }
  )

// Extract the discriminating TAG constructor name from a variant Object schema's
// `items`. sury compiles a record-payload variant `Foo({...})` to an Object whose
// `items` carry one entry at location "TAG" holding a `String` const = "Foo".
// Returns None for a non-tagged object (no TAG item, or a non-const schema).
// Single source for the ~dozen previously-inlined identical extractions across
// this file, DcbDecode and DcbValidation.
let variantTagName = (items: array<S.item>): option<string> =>
  items
  ->Array.find(item => item.location == "TAG")
  ->Option.flatMap(item =>
    switch item.schema {
    | String({const}) => Some(const)
    | _ => None
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
            if variantTagName(items) == jsonTag {
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
  let json = value->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow
  extractTagsFromJson(schema->toUnknownSchema, json)
}

// --- Extract variant constructor names from a tagged union schema ---
// For a variant type like `type event = ItemCreated({...}) | ItemRenamed({...})`,
// this extracts ["ItemCreated", "ItemRenamed"]

/**
Extracts all variant constructor names from a tagged union schema.

Works on any `@schema`-annotated variant type: events, commands, errors, consumed events.
For `CatalogEventLog.event` returns
`["ProductAdded", "ProductNameUpdated", ..., "CategoryAdded", ...]`.
Used by the DCB runtime to build `queryItem.eventTypes` arrays automatically.
*/
let extractVariantNames = (schema: S.t<'a>): array<string> => {
  switch schema->toUnknownSchema {
  | Union({anyOf}) =>
    anyOf->Array.filterMap(variantSchema =>
      switch variantSchema {
      | Object({items}) => variantTagName(items)
      // Payload-less variants (sury-compiled `S.literal("Name")` strings) are
      // intentionally excluded here: DCB event-type lookups can't WHERE-clause
      // on bare-string events, so Plugin_Structure.consumedEventTypes and
      // related graph fields would otherwise claim cross-component edges the
      // runtime can't honour. Callers that need every constructor (e.g.
      // mapping-mode `acceptedTags` filters that match a JSON envelope's
      // `event` TAG against the Delegate's full constructor set) should call
      // [`extractAllVariantNames`] instead.
      | _ => None
      }
    )
  | Object({items}) => variantTagName(items)->Option.mapOr([], t => [t])
  | _ => []
  }
}

/**
Like [`extractVariantNames`], but also includes payload-less variants
(constructors compiled to `S.literal("Name")`).

Use for **command schemas** where every constructor must be addressable
(GraphQL mutation field derivation, plugin schema reporting, runtime
dispatch). [`extractVariantNames`] keeps the payload-less filter required by
DCB event-type lookups, where bare-string events carry no `type` field for
WHERE-clause filtering.
*/
let extractAllVariantNames = (schema: S.t<'a>): array<string> => {
  switch schema->toUnknownSchema {
  | Union({anyOf}) =>
    anyOf->Array.filterMap(variantSchema =>
      switch variantSchema {
      | Object({items}) => variantTagName(items)
      | String({const}) => Some(const)
      | _ => None
      }
    )
  | Object({items}) => variantTagName(items)->Option.mapOr([], t => [t])
  | String({const: ?Some(name)}) => [name]
  | _ => []
  }
}

/**
Returns `true` if the given variant constructor (by name) carries a record
payload (compiled to `{TAG, ...}`), `false` if payload-less (compiled to a
bare string literal). Returns `false` for names not found in the schema.

Used by resolver shims to synthesize the correct runtime shape when feeding
a command value into the PPX-generated `commandAuthorization` switch.
*/
let isVariantPayloadBearing = (schema: S.t<'a>, name: string): bool => {
  // Returns true iff a record-payload variant in the schema has TAG === name.
  // Payload-less variants compile to S.literal("X") (String const), so they
  // are not "payload-bearing" — only Object schemas with a matching TAG are.
  let names = extractAllVariantNames(schema)
  if !(names->Array.includes(name)) {
    false
  } else {
    switch schema->toUnknownSchema {
    | Union({anyOf}) =>
      anyOf->Array.some(variantSchema =>
        switch variantSchema {
        | Object({items}) => variantTagName(items)->Option.mapOr(false, t => t == name)
        | _ => false
        }
      )
    | Object({items}) => variantTagName(items)->Option.mapOr(false, t => t == name)
    | _ => false
    }
  }
}

// --- Array-expanded tag extraction ---

/**
Extracts tags from a flat JSON object, expanding array values into per-element tags.

For scalar tagged fields, behaves identically to `extractTagsFromProperties`.
For array tagged fields, produces one tag per element. Tag keys honour an optional
`DcbTag.stringForKey(~key=...)` override on the (inner) schema; otherwise the field
name is used.
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
      | Some(jsonValue) => [
          {key: resolveTagKey(fieldName, fieldSchema), value: jsonValue->jsonValueToString},
        ]
      | None => []
      }
    } else if isTaggedArray(fieldSchema) {
      switch jsonDict->Dict.get(fieldName) {
      | Some(JSON.Array(elements)) => {
          let tagKey = resolveArrayTagKey(fieldName, fieldSchema)
          elements->Array.map(element => {key: tagKey, value: element->jsonValueToString})
        }
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
            if variantTagName(items) == jsonTag {
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
  let json = value->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow
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
Collects the produced tag keys of one event-schema variant: the resolved tag key
of every scalar tagged field plus the resolved (override-aware) tag key of every
tagged-array field.
*/
let tagKeysOfProperties = (properties: dict<S.t<unknown>>): array<string> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((fieldName, fieldSchema)) =>
    if isTagged(fieldSchema) {
      Some(resolveTagKey(fieldName, fieldSchema))
    } else if isTaggedArray(fieldSchema) {
      Some(resolveArrayTagKey(fieldName, fieldSchema))
    } else {
      None
    }
  )

/**
Maps each event-type (variant constructor name) to the set of DCB tag keys that
type can carry, read from a *produced* event-log schema.

This is the lookup the query builder uses to drop vacuous (type, tag) clause
combinations: an event type is kept in a tag clause only if its produced tag set
contains that tag. Built from the producer schema (not a consumer's
`consumedEventSchema`, which may legitimately under-declare tags it reads by).

For `CatalogEventLog.event` (`ProductAdded({productId})` | `CategoryAdded({categoryId})`)
returns `{"ProductAdded": ["productId"], "CategoryAdded": ["categoryId"]}`.
*/
let extractTagKeysByEventType = (schema: S.t<'a>): dict<array<string>> => {
  let result = Dict.make()
  let addVariant = (variantSchema: S.t<unknown>) =>
    switch variantSchema {
    | Object({items, properties}) =>
      variantTagName(items)->Option.forEach(eventType =>
        result->Dict.set(eventType, tagKeysOfProperties(properties))
      )
    | _ => ()
    }
  switch schema->toUnknownSchema {
  | Union({anyOf}) => anyOf->Array.forEach(addVariant)
  | Object(_) as obj => addVariant(obj)
  | _ => ()
  }
  result
}

/**
Merges several per-event-type tag-key maps into one (later entries win on key
collision, which is irrelevant here since a given event type is produced once).
*/
let mergeTagKeysByEventType = (maps: array<dict<array<string>>>): dict<array<string>> => {
  let merged = Dict.make()
  maps->Array.forEach(m =>
    m->Dict.toArray->Array.forEach(((eventType, keys)) => merged->Dict.set(eventType, keys))
  )
  merged
}

/**
Narrows a clause's event-type list to those types whose produced tag set can
carry *all* of the clause's tags. A type absent from `tagKeysByEventType` is
kept (we can't prove it vacuous). Removing a vacuous (type, tag) pairing cannot
change query results — such a type can never satisfy the clause's tags anyway.
*/
let narrowEventTypesForTags = (
  eventTypes: array<string>,
  tags: array<tag>,
  tagKeysByEventType: dict<array<string>>,
): array<string> =>
  eventTypes->Array.filter(eventType =>
    switch tagKeysByEventType->Dict.get(eventType) {
    | None => true
    | Some(producedKeys) =>
      tags->Array.every(tag => producedKeys->Array.includes(tag.key))
    }
  )

/**
Builds a DCB query from a command value and its schema.

Automatically detects the query mode from the schema:
- If the schema has tagged array fields → cross-entity mode: each tag becomes
  its own OR clause (per-element expansion for arrays).
- Otherwise → single-entity mode: all tags go into one AND clause.

When `~tagKeysByEventType` is supplied (the produced event-log schema's
type→tag-key map), each clause drops event types whose produced tag set cannot
carry the clause's tag(s) — e.g. a `CatalogProductSynced` type is removed from
an `orderId` clause. This is pure dead-clause removal: a vacuous (type, tag)
pairing matches nothing, so results are unchanged. A type that carries the tag
as a *secondary* tag is retained (a legitimate cross-partition read), and a type
absent from the map is kept (cannot be proven vacuous).

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
let buildQueryFromCommand = (
  ~eventTypes,
  ~schema: S.t<'a>,
  ~value: 'a,
  ~tagKeysByEventType: dict<array<string>>=Dict.make(),
  ~crossPartitionTagKeys: array<string>=[],
): query => {
  let typesForTags = clauseTags => narrowEventTypesForTags(eventTypes, clauseTags, tagKeysByEventType)
  if hasTaggedArrayFields(schema) {
    // Array fields already fan out per element into single-tag clauses, so a
    // cross-partition array tag is already its own clause (the adapter routes it
    // by `crossPartitionTagKeys`).
    let tags = extractTagsExpanded(schema, value)
    tags->Array.map(tag => {
      let clauseTags = [{key: tag.key, value: tag.value}]
      {eventTypes: typesForTags(clauseTags), tags: clauseTags}
    })
  } else {
    let tags = extractTags(schema, value)
    // When any command tag is cross-partition, fan every scalar tag out into its
    // own single-tag clause instead of AND-ing them into one composite
    // (exact-pair) clause. An M:N command (`SubscribeStudent({courseId, studentId})`)
    // must read "all of the course" AND "all of the student" as two single-tag
    // reads — a composite read of the exact `{course, student}` pair is neither.
    // Without a cross-partition tag the default composite clause is preserved.
    let hasCrossPartition =
      tags->Array.some(tag => crossPartitionTagKeys->Array.includes(tag.key))
    if hasCrossPartition && tags->Array.length > 1 {
      tags->Array.map(tag => {
        let clauseTags = [{key: tag.key, value: tag.value}]
        {eventTypes: typesForTags(clauseTags), tags: clauseTags}
      })
    } else {
      [{eventTypes: typesForTags(tags), tags}]
    }
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

/**
Collects the *cross-partition* tag keys of one object-variant's properties: the
resolved (override-aware) tag key of every scalar field marked
`DcbTag.crossPartition`, plus that of every array field whose element is.
*/
let crossPartitionKeysOfProperties = (properties: dict<S.t<unknown>>): array<string> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((fieldName, fieldSchema)) =>
    if isTagged(fieldSchema) && isCrossPartitionTag(fieldSchema) {
      Some(resolveTagKey(fieldName, fieldSchema))
    } else if isCrossPartitionTaggedArray(fieldSchema) {
      Some(resolveArrayTagKey(fieldName, fieldSchema))
    } else {
      None
    }
  )

/**
Extracts the set of DCB tag keys declared cross-partition (`@crossPartition`)
across all variants of an event or command schema.

Returns a sorted, deduplicated list of tag keys. The scope is a property of the
tag key, so this set is derived once at build time (from the *produced* event
schemas) and threaded to both the decision-model query builder (to fan a
cross-partition scalar tag into its own single-tag clause) and the storage
adapter (read routing + fence scope).

For an event schema `StudentSubscribed({@partitionTag courseId, @crossPartition studentId})`
returns `["studentId"]`.
*/
let extractCrossPartitionTagKeys = (schema: S.t<'event>): array<string> => {
  let keys = switch schema->toUnknownSchema {
  | Union({anyOf}) =>
    anyOf->Array.flatMap(variantSchema =>
      switch variantSchema {
      | Object({properties}) => crossPartitionKeysOfProperties(properties)
      | _ => []
      }
    )
  | Object({properties}) => crossPartitionKeysOfProperties(properties)
  | _ => []
  }
  let seen = Set.make()
  keys->Array.forEach(k => seen->Set.add(k))
  Array.fromIterator(seen->Set.values)->Array.toSorted((a, b) => String.compare(a, b))
}

// --- Schema -> DcbScopeInference shapes (the runtime adapter) ---

/**
Collects the `*Id` / `*Ids`-shaped fields of one object-variant's properties as
`DcbScopeInference.idField`s — by **name**, independent of any DCB tag flag. This
is the un-annotated structural view the scope inference consumes.
*/
let idFieldsOfProperties = (properties: dict<S.t<unknown>>): array<DcbScopeInference.idField> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((name, fieldSchema)) =>
    if name->String.endsWith("Ids") || name->String.endsWith("Id") {
      let isList = switch fieldSchema {
      | Array(_) => true
      | _ => false
      }
      Some({DcbScopeInference.name, isList})
    } else {
      None
    }
  )

/**
Extracts the `DcbScopeInference.eventShape`s (variant name + `*Id` fields) from a
variant schema. Payload-less arms are kept (no id fields); non-variant schemas
return a single shape.
*/
let eventShapesOfSchema = (schema: S.t<'a>): array<DcbScopeInference.eventShape> => {
  let ofVariant = (variantSchema: S.t<unknown>): option<DcbScopeInference.eventShape> =>
    switch variantSchema {
    | Object({items, properties}) =>
      variantTagName(items)->Option.map(eventType => {
        DcbScopeInference.eventType,
        idFields: idFieldsOfProperties(properties),
      })
    | String({const}) => Some({DcbScopeInference.eventType: const, idFields: []})
    | _ => None
    }
  switch schema->toUnknownSchema {
  | Union({anyOf}) => anyOf->Array.filterMap(ofVariant)
  | Object(_) as obj => ofVariant(obj)->Option.mapOr([], s => [s])
  | _ => []
  }
}

// --- Partition tag derivation ---

/**
Extracts field names annotated with `@s.matches(DcbTag.partition)` from an event schema.
*/
let extractPartitionTagFields = (schema: S.t<'event>): array<string> => {
  switch schema->toUnknownSchema {
  | Union({anyOf}) =>
    let allFields = anyOf->Array.flatMap(variantSchema =>
      switch variantSchema {
      | Object({properties}) =>
        properties
        ->Dict.toArray
        ->Array.filterMap(((fieldName, fieldSchema)) =>
          if isPartitionTag(fieldSchema) {
            Some(fieldName)
          } else {
            None
          }
        )
      | _ => []
      }
    )
    let fieldSet = Set.make()
    allFields->Array.forEach(field => fieldSet->Set.add(field))
    Array.fromIterator(fieldSet->Set.values)

  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((fieldName, fieldSchema)) =>
      if isPartitionTag(fieldSchema) {
        Some(fieldName)
      } else {
        None
      }
    )

  | _ => []
  }
}

/**
Builds the `DcbScopeInference.sliceShape` for one slice from its sury schemas.
The `command` fields are flattened across command variants; `consumed` / `produced`
keep their per-arm structure. Schema-coupling lives here so the inference core
stays schema-agnostic.
*/
let sliceShapeFromSchemas = (
  ~name: string,
  ~commandSchema: S.t<'c>,
  ~consumedEventSchema: S.t<'ce>,
  ~eventSchema: S.t<'e>,
): DcbScopeInference.sliceShape => {
  // An explicit @partitionTag on the produced event is the escape hatch for
  // slices whose own events carry two owned keys (e.g. RecordProductDemand).
  let partitionHint = switch extractPartitionTagFields(eventSchema) {
  | [single] => Some(single)
  | _ => None
  }
  {
    sliceName: name,
    command: eventShapesOfSchema(commandSchema)->Array.flatMap(e => e.idFields),
    consumed: eventShapesOfSchema(consumedEventSchema),
    produced: eventShapesOfSchema(eventSchema),
    partitionHint,
  }
}

/**
Checks whether any single variant in a schema has multiple tagged fields.
If so, a partition tag annotation is needed to disambiguate.
*/
let hasMultiTagVariant = (schema: S.t<unknown>): bool =>
  switch schema {
  | Union({anyOf}) =>
    anyOf->Array.some(variantSchema =>
      switch variantSchema {
      | Object({properties}) => {
          let tagCount =
            properties
            ->Dict.toArray
            ->Array.filter(((_, fieldSchema)) => isTagged(fieldSchema))
            ->Array.length
          tagCount > 1
        }
      | _ => false
      }
    )
  | Object({properties}) => {
      let tagCount =
        properties
        ->Dict.toArray
        ->Array.filter(((_, fieldSchema)) => isTagged(fieldSchema))
        ->Array.length
      tagCount > 1
    }
  | _ => false
  }

/**
Returns the names of variants within a schema that have multiple tagged fields.
Used to build diagnostic context for partition tag errors.
*/
let findMultiTagVariantNames = (schema: S.t<unknown>): array<string> => {
  // Extract the variant name from a single object-variant schema via its TAG item.
  let variantName = (variantSchema: S.t<unknown>): option<string> =>
    switch variantSchema {
    | Object({items, properties}) => {
        let tagCount =
          properties
          ->Dict.toArray
          ->Array.filter(((_, fieldSchema)) => isTagged(fieldSchema))
          ->Array.length
        if tagCount > 1 {
          Some(variantTagName(items)->Option.getOr("(unknown)"))
        } else {
          None
        }
      }
    | _ => None
    }

  switch schema {
  | Union({anyOf}) => anyOf->Array.filterMap(variantName)
  | _ =>
    // Single-variant event type — schema is the object directly
    switch variantName(schema) {
    | Some(name) => [name]
    | None => []
    }
  }
}

// --- Composite partition key helpers ---

type compositePartitionFieldInfo = {name: string, position: int, sep: string}

/**
Extracts all composite partition member fields from a single object-variant schema.
Returns an array sorted by `position`.
*/
let extractCompositePartitionFieldsFromProperties = (
  properties: dict<S.t<unknown>>,
): array<compositePartitionFieldInfo> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((fieldName, fieldSchema)) =>
    switch S.Metadata.get(fieldSchema, ~id=dcbCompositePartitionMemberId) {
    | Some(meta) => Some({name: fieldName, position: meta.position, sep: meta.sep})
    | None => None
    }
  )
  ->Array.toSorted((a, b) => Int.compare(a.position, b.position))

/**
Extracts all composite partition member fields across all variants of a schema.
Returns deduplicated entries sorted by position (assumes all variants agree on positions).
*/
let extractCompositePartitionFields = (schema: S.t<'event>): array<compositePartitionFieldInfo> => {
  let seen = Set.make()
  let collect = (properties: dict<S.t<unknown>>) =>
    extractCompositePartitionFieldsFromProperties(properties)->Array.filter(info => {
      if seen->Set.has(info.name) {
        false
      } else {
        seen->Set.add(info.name)
        true
      }
    })
  switch schema->toUnknownSchema {
  | Union({anyOf}) =>
    anyOf->Array.flatMap(variantSchema =>
      switch variantSchema {
      | Object({properties}) => collect(properties)
      | _ => []
      }
    )
  | Object({properties}) => collect(properties)
  | _ => []
  }
}

/**
Computes the composite partition key value from an array of tags and a spec.
Joins the tag values in key order, inserting separators between them.
*/
let getCompositePartitionKeyValue = (tags: array<tag>, spec: compositePartitionSpec): string =>
  spec.keys
  ->Array.mapWithIndex((fieldName, i) => {
    let v =
      tags->Array.findMap(t => if t.key == fieldName {Some(t.value)} else {None})->Option.getOr("")
    if i == 0 {
      v
    } else {
      spec.seps->Array.getUnsafe(i - 1) ++ v
    }
  })
  ->Array.join("")

// --- Partition tag derivation ---

/**
Derives the partition tag strategy from an array of named event schemas.

Returns `Simple(partitionTag)` when the schema uses `@partitionTag` (or a single tag),
or `Composite(compositePartitionSpec)` when it uses `@compositePartitionTag`.

Rules for simple strategy:
- If only one tagged field exists across all schemas, it is automatically selected.
- If multiple tagged fields exist but each event variant has at most one tagged
  field (multi-entity DCB), the first field alphabetically is selected.
- If any event variant has multiple tagged fields and exactly one is annotated
  with `DcbTag.partition`, that one is selected.
- If any event variant has multiple tagged fields and none (or multiple) are
  annotated with `DcbTag.partition`, throws an error naming the affected slice,
  variant(s), and source file path.

Throws when:
- A schema mixes `@compositePartitionTag` and `@partitionTag` fields.
- Fewer than 2 fields are annotated with `@compositePartitionTag`.
*/
let derivePartitionTag = (
  namedSchemas: array<(string, string, S.t<unknown>)>,
): derivedPartitionTag => {
  let schemas = namedSchemas->Array.map(((_, _, schema)) => schema)

  let allCompositeFields = {
    let seen = Set.make()
    schemas
    ->Array.flatMap(schema => extractCompositePartitionFields(schema))
    ->Array.filter(info => {
      if seen->Set.has(info.name) {
        false
      } else {
        seen->Set.add(info.name)
        true
      }
    })
  }

  let hasComposite = allCompositeFields->Array.length > 0

  let allPartitionFields = {
    let seen = Set.make()
    schemas->Array.flatMap(schema => extractPartitionTagFields(schema))->Array.filter(f => {
      if seen->Set.has(f) {
        false
      } else {
        seen->Set.add(f)
        true
      }
    })
  }

  if hasComposite && allPartitionFields->Array.length > 0 {
    JsError.throwWithMessage(
      `DCB spec mixes @compositePartitionTag and @partitionTag — use one strategy per schema`,
    )
  }

  if hasComposite {
    if allCompositeFields->Array.length < 2 {
      JsError.throwWithMessage(
        `@compositePartitionTag requires at least 2 annotated fields — only ${allCompositeFields->Array.length->Int.toString} found`,
      )
    }
    let sorted = allCompositeFields->Array.toSorted((a, b) => Int.compare(a.position, b.position))
    let keys = sorted->Array.map(info => info.name)
    let seps = sorted->Array.slice(~start=0, ~end=sorted->Array.length - 1)->Array.map(info =>
      info.sep
    )
    Composite({keys, seps})
  } else {
    let allTaggedFields = {
      let seen = Set.make()
      schemas->Array.flatMap(schema => extractTaggedFields(schema))->Array.filter(f => {
        if seen->Set.has(f) {
          false
        } else {
          seen->Set.add(f)
          true
        }
      })
    }

    switch allTaggedFields {
    | [] => JsError.throwWithMessage("DCB spec has no tagged fields — cannot derive partition tag")
    | [singleField] => Simple({key: singleField})
    | multipleFields => {
        let needsExplicitPartition = schemas->Array.some(schema => hasMultiTagVariant(schema))

        if needsExplicitPartition {
          let context =
            namedSchemas
            ->Array.filterMap(((sliceName, path, schema)) => {
              let variantNames = findMultiTagVariantNames(schema)
              if variantNames->Array.length > 0 {
                Some(`${sliceName} (${variantNames->Array.join(", ")}) @ ${path}`)
              } else {
                None
              }
            })
            ->Array.join(", ")

          switch allPartitionFields {
          | [singlePartition] => Simple({key: singlePartition})
          | [] =>
            JsError.throwWithMessage(
              `DCB spec has variants with multiple tagged fields (${multipleFields->Array.join(", ")}) but none is annotated with @partitionTag — affected: ${context} — mark one field as the partition key`,
            )
          | multiplePartitions =>
            JsError.throwWithMessage(
              `DCB spec has multiple fields annotated with @partitionTag (${multiplePartitions->Array.join(", ")}) — only one is allowed — affected: ${context}`,
            )
          }
        } else {
          let sorted = multipleFields->Array.toSorted((a, b) => String.compare(a, b))
          Simple({key: sorted->Array.getUnsafe(0)})
        }
      }
    }
  }
}

/**
Extracts the partition tag value from a query.
Returns the value of the first tag matching the partition tag key, or None if not found.
*/
let getPartitionTagValue = (query: query, pt: partitionTag): option<string> =>
  query
  ->Array.filterMap(queryItem =>
    switch queryItem.tags {
    | Some(tags) =>
      tags->Array.findMap(tag =>
        if tag.key == pt.key {
          Some(tag.value)
        } else {
          None
        }
      )
    | None => None
    }
  )
  ->Array.get(0)
