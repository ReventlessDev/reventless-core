// --- Tag types ---
type tag = {key: string, value: string}

type queryItem = {
  eventTypes?: array<string>,
  tags?: array<tag>,
}

type query = array<queryItem>

type sequencePosition = string

type appendCondition = {
  query: query,
  after?: sequencePosition,
}

// --- Sury metadata for tag annotation ---

let dcbTagId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="dcb", ~name="tag")

let string: S.t<string> = S.string->S.Metadata.set(~id=dcbTagId, true)
let int: S.t<int> = S.int->S.Metadata.set(~id=dcbTagId, true)

// --- Tag extraction from sury schemas ---

external toUnknownSchema: S.t<'a> => S.t<unknown> = "%identity"

let isTagged = (fieldSchema: S.t<unknown>) =>
  S.Metadata.get(fieldSchema, ~id=dcbTagId)->Option.isSome

let jsonValueToString = json =>
  switch json {
  | JSON.String(s) => s
  | JSON.Number(n) => n->Float.toString
  | JSON.Boolean(b) => b ? "true" : "false"
  | _ => json->JSON.stringify
  }

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

let extractTags = (schema: S.t<'a>, value: 'a): array<tag> => {
  let json = value->S.reverseConvertToJsonOrThrow(schema)
  extractTagsFromJson(schema->toUnknownSchema, json)
}

// --- Extract event type names from event schema ---
// For a variant type like `type event = ItemCreated({...}) | ItemRenamed({...})`,
// this extracts ["ItemCreated", "ItemRenamed"]

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
