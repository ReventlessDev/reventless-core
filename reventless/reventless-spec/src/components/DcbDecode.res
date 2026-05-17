// Decodes raw stored events against a consumed event schema.
// Supports the full spectrum of consumed events:
//   - Payload-less variants (match by TAG only, bypass sury)
//   - Partial projections (sury parse with field subset)
//   - Full shape (sury parse as-is)

// Build a lookup of TAG name -> variant kind (payloadLess or withFields)
// from a consumed event schema. Cached per schema for performance.

type variantKind =
  | PayloadLess
  | WithFields

// In sury alpha.5 the `items` array on `S.t.Object` is gone; the discriminant
// "TAG" lives in `properties` alongside the payload fields. A variant is
// payload-less when `properties` has only the TAG entry (length <= 1).
let extractTagFromProperties = (properties: dict<S.t<unknown>>): option<string> =>
  properties
  ->Dict.get("TAG")
  ->Option.flatMap(s =>
    switch s {
    | String({const}) => Some(const)
    | _ => None
    }
  )

let buildVariantLookup = (schema: S.t<unknown>): dict<variantKind> => {
  let lookup = Dict.make()
  switch schema {
  | Union({anyOf}) =>
    anyOf->Array.forEach(variantSchema =>
      switch variantSchema {
      | Object({properties}) =>
        switch extractTagFromProperties(properties) {
        | Some(name) =>
          let kind = if properties->Dict.keysToArray->Array.length <= 1 {
            PayloadLess
          } else {
            WithFields
          }
          lookup->Dict.set(name, kind)
        | None => ()
        }
      | String({const: ?Some(name)}) =>
        // sury represents payload-less variants in some cases as bare String({const})
        lookup->Dict.set(name, PayloadLess)
      | _ => ()
      }
    )
  | Object({properties}) =>
    // Single-variant schema with fields
    switch extractTagFromProperties(properties) {
    | Some(name) => lookup->Dict.set(name, WithFields)
    | None => ()
    }
  | String({const: ?Some(name)}) =>
    // Single payload-less variant — sury compiles `type t = Foo` to String({const: "Foo"})
    lookup->Dict.set(name, PayloadLess)
  | _ => ()
  }
  lookup
}

type decoder<'event> = {
  lookup: dict<variantKind>,
  schema: S.t<'event>,
  constructors: dict<'event>,
}

external unsafeCast: 'a => 'b = "%identity"

// Build a map of TAG name -> constructed payload-less variant value
// by encoding each payload-less variant through sury and storing the result.
// This is done once per schema, not per event.
let buildPayloadLessConstructors = (schema: S.t<'event>, lookup: dict<variantKind>): dict<'event> => {
  let constructors = Dict.make()
  // For payload-less variants, we need to figure out what ReScript value
  // corresponds to each TAG name. sury's schema for a union with payload-less
  // variants encodes them as bare strings. So `| ItemCreated` serializes to
  // JSON string "ItemCreated". We can use Util_Sury.fromJson with the string.
  lookup->Dict.toArray->Array.forEach(((tagName, kind)) =>
    switch kind {
    | PayloadLess =>
      try {
        let value = JSON.String(tagName)->Util_Sury.fromJson(schema)
        constructors->Dict.set(tagName, value)
      } catch {
      | _ => ()
      }
    | WithFields => ()
    }
  )
  constructors
}

type makeDecoderResult<'event> = {
  decode: (~eventType: string, ~data: dict<JSON.t>) => option<'event>,
  eventTypes: array<string>,
}

let makeDecoder = (schema: S.t<'event>): makeDecoderResult<'event> => {
  let unknownSchema: S.t<unknown> = unsafeCast(schema)
  let lookup = buildVariantLookup(unknownSchema)
  let constructors = buildPayloadLessConstructors(schema, lookup)
  let eventTypes = lookup->Dict.keysToArray

  let decode = (~eventType: string, ~data: dict<JSON.t>): option<'event> =>
    switch lookup->Dict.get(eventType) {
    | None => None
    | Some(PayloadLess) => constructors->Dict.get(eventType)
    | Some(WithFields) =>
      // Reconstruct the JSON with TAG for sury parsing
      let jsonDict = data->Dict.copy
      jsonDict->Dict.set("TAG", JSON.String(eventType))
      try {
        Some(JSON.Object(jsonDict)->Util_Sury.fromJson(schema))
      } catch {
      | _ => None
      }
    }

  {decode, eventTypes}
}
