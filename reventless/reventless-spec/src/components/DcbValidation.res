type validationError = {
  sliceName: string,
  message: string,
}

type variantInfo = {
  tagName: string,
  fields: dict<S.t<unknown>>,
  taggedFields: array<string>,
}

// Extract variant info (TAG name, fields, tagged fields) from a single variant schema.
//
// In sury alpha.5 the "TAG" entry lives in `properties` alongside the payload
// fields (the alpha.4 `items` array was removed). The `fields` returned here
// is the payload-only view — TAG is filtered out so downstream rules treat
// it like alpha.4 did.
let extractVariantInfo = (variantSchema: S.t<unknown>): option<variantInfo> =>
  switch variantSchema {
  | Object({properties}) =>
    DcbTag.extractTagConst(properties)->Option.map(tagName => {
      let payloadFields = Dict.make()
      properties->Dict.toArray->Array.forEach(((key, schema)) =>
        if key != "TAG" {
          payloadFields->Dict.set(key, schema)
        }
      )
      let taggedFields =
        payloadFields
        ->Dict.toArray
        ->Array.filterMap(((fieldName, fieldSchema)) =>
          if DcbTag.isTagged(fieldSchema) {
            Some(fieldName)
          } else {
            None
          }
        )
      {tagName, fields: payloadFields, taggedFields}
    })
  | _ => None
  }

// Extract all variant infos from a schema (handles Union and single Object)
let extractAllVariants = (schema: S.t<unknown>): array<variantInfo> =>
  switch schema {
  | Union({anyOf}) => anyOf->Array.filterMap(extractVariantInfo)
  | Object(_) =>
    switch extractVariantInfo(schema) {
    | Some(info) => [info]
    | None => []
    }
  | String({const: ?Some(name)}) =>
    // Single payload-less variant — sury compiles `type t = Foo` to String({const: "Foo"})
    [{tagName: name, fields: Dict.make(), taggedFields: []}]
  | _ => []
  }

// Check if a variant has no payload fields (only TAG)
let isPayloadLess = (info: variantInfo): bool => info.fields->Dict.toArray->Array.length == 0

// Compare two sury schema types for structural compatibility
let rec schemasAreCompatible = (a: S.t<unknown>, b: S.t<unknown>): bool =>
  switch (a, b) {
  | (String(_), String(_)) => true
  | (Number(_), Number(_)) => true
  | (Boolean(_), Boolean(_)) => true
  | (BigInt(_), BigInt(_)) => true
  | (Array({additionalItems: Schema(aItem)}), Array({additionalItems: Schema(bItem)})) =>
    schemasAreCompatible(aItem, bItem)
  | (Union(_), Union(_)) => true
  | (Object(_), Object(_)) => true
  | _ => false
  }

// Get a human-readable type name for a schema
let schemaTypeName = (schema: S.t<unknown>): string =>
  switch schema {
  | String(_) => "string"
  | Number(_) => "float"
  | Boolean(_) => "bool"
  | BigInt(_) => "bigint"
  | Array(_) => "array"
  | Object(_) => "object"
  | Union(_) => "union"
  | Never(_) => "never"
  | Unknown(_) => "unknown"
  | Ref(_) => "ref"
  | _ => "unknown"
  }

type producerEntry = {
  sliceName: string,
  variant: variantInfo,
}

let validateProducedAndConsumed = (
  ~produced: array<(string, S.t<unknown>)>,
  ~consumed: array<(string, S.t<unknown>)>,
): result<unit, array<validationError>> => {
  let errors: array<validationError> = []

  // Build a map of TAG name -> array of (sliceName, variantInfo) for produced events
  let producerMap: dict<array<producerEntry>> = Dict.make()
  produced->Array.forEach(((sliceName, schema)) => {
    let variants = extractAllVariants(schema)
    variants->Array.forEach(variant => {
      let existing = producerMap->Dict.get(variant.tagName)->Option.getOr([])
      producerMap->Dict.set(variant.tagName, existing->Array.concat([{sliceName, variant}]))
    })
  })

  // Rule 1: Payload equivalence across producers
  // All producers of the same TAG must have identical fields, types, and tag annotations
  producerMap->Dict.toArray->Array.forEach(((tagName, entries)) => {
    if entries->Array.length > 1 {
      let first = entries->Array.getUnsafe(0)
      let firstFields = first.variant.fields->Dict.keysToArray->Array.toSorted(String.compare)
      let firstTagged = first.variant.taggedFields->Array.toSorted(String.compare)

      entries->Array.forEachWithIndex((entry, idx) => {
        if idx > 0 {
          let entryFields = entry.variant.fields->Dict.keysToArray->Array.toSorted(String.compare)
          let entryTagged = entry.variant.taggedFields->Array.toSorted(String.compare)

          // Check field names match
          if firstFields->Array.length != entryFields->Array.length ||
            firstFields->Array.some(f => !(entryFields->Array.includes(f))) {
            let missingInEntry =
              firstFields->Array.filter(f => !(entryFields->Array.includes(f)))
            let extraInEntry =
              entryFields->Array.filter(f => !(firstFields->Array.includes(f)))
            let parts = []
            if missingInEntry->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `'${first.sliceName}' has fields [${missingInEntry->Array.join(", ")}] which '${entry.sliceName}' is missing`,
                )
            }
            if extraInEntry->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `'${entry.sliceName}' has fields [${extraInEntry->Array.join(", ")}] which '${first.sliceName}' is missing`,
                )
            }
            let _ =
              errors->Array.push({
                sliceName: entry.sliceName,
                message: `Producers '${first.sliceName}' and '${entry.sliceName}' both produce '${tagName}' but with different fields: ${parts->Array.join("; ")}`,
              })
          } else {
            // Fields match by name — check types are compatible
            firstFields->Array.forEach(fieldName => {
              let firstSchema = first.variant.fields->Dict.getUnsafe(fieldName)
              let entrySchema = entry.variant.fields->Dict.getUnsafe(fieldName)
              if !schemasAreCompatible(firstSchema, entrySchema) {
                let _ =
                  errors->Array.push({
                    sliceName: entry.sliceName,
                    message: `Producers '${first.sliceName}' and '${entry.sliceName}' both produce '${tagName}' but field '${fieldName}' has type '${schemaTypeName(firstSchema)}' in '${first.sliceName}' and '${schemaTypeName(entrySchema)}' in '${entry.sliceName}'`,
                  })
              }
            })
          }

          // Check tag annotations match
          if firstTagged->Array.length != entryTagged->Array.length ||
            firstTagged->Array.some(f => !(entryTagged->Array.includes(f))) {
            let untaggedInEntry =
              firstTagged->Array.filter(f => !(entryTagged->Array.includes(f)))
            let untaggedInFirst =
              entryTagged->Array.filter(f => !(firstTagged->Array.includes(f)))
            let parts = []
            if untaggedInEntry->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `[${untaggedInEntry->Array.join(", ")}] tagged in '${first.sliceName}' but not in '${entry.sliceName}'`,
                )
            }
            if untaggedInFirst->Array.length > 0 {
              let _ =
                parts->Array.push(
                  `[${untaggedInFirst->Array.join(", ")}] tagged in '${entry.sliceName}' but not in '${first.sliceName}'`,
                )
            }
            let _ =
              errors->Array.push({
                sliceName: entry.sliceName,
                message: `Producers '${first.sliceName}' and '${entry.sliceName}' both produce '${tagName}' but tag annotations differ: ${parts->Array.join("; ")}`,
              })
          }
        }
      })
    }
  })

  // Rule 2: Every consumed event has a producer
  // Rule 3: Consumed fields exist in produced shape (payload-less always valid)
  // Rule 4: Type compatibility
  consumed->Array.forEach(((sliceName, schema)) => {
    let variants = extractAllVariants(schema)
    variants->Array.forEach(variant => {
      switch producerMap->Dict.get(variant.tagName) {
      | None =>
        let _ =
          errors->Array.push({
            sliceName,
            message: `Slice '${sliceName}' consumes '${variant.tagName}' but no slice produces it`,
          })
      | Some(producers) =>
        // Use first producer as the authoritative shape (Rule 1 ensures they're all identical)
        let producer = producers->Array.getUnsafe(0)

        // Skip field checks for payload-less consumed variants
        if !isPayloadLess(variant) {
          variant.fields->Dict.toArray->Array.forEach(((fieldName, consumedFieldSchema)) => {
            switch producer.variant.fields->Dict.get(fieldName) {
            | None =>
              let _ =
                errors->Array.push({
                  sliceName,
                  message: `Slice '${sliceName}' consumes '${variant.tagName}.${fieldName}' (${schemaTypeName(consumedFieldSchema)}) but produced '${variant.tagName}' has no field '${fieldName}'`,
                })
            | Some(producedFieldSchema) =>
              if !schemasAreCompatible(consumedFieldSchema, producedFieldSchema) {
                let _ =
                  errors->Array.push({
                    sliceName,
                    message: `Slice '${sliceName}' consumes '${variant.tagName}.${fieldName}' as ${schemaTypeName(consumedFieldSchema)} but producer declares it as ${schemaTypeName(producedFieldSchema)}`,
                  })
              }
            }
          })
        }
      }
    })
  })

  if errors->Array.length > 0 {
    Error(errors)
  } else {
    Ok()
  }
}
