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

let buildVariantLookup = (schema: S.t<unknown>): dict<variantKind> => {
  let lookup = Dict.make()
  switch schema {
  | Union({anyOf}) =>
    anyOf->Array.forEach(variantSchema =>
      switch variantSchema {
      | Object({items, properties}) =>
        let tagName =
          items
          ->Array.find(item => item.location == "TAG")
          ->Option.flatMap(item =>
            switch item.schema {
            | String({const}) => Some(const)
            | _ => None
            }
          )
        switch tagName {
        | Some(name) =>
          let kind = if properties->Dict.keysToArray->Array.length == 0 {
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
  | Object({items}) =>
    // Single-variant schema with fields
    let tagName =
      items
      ->Array.find(item => item.location == "TAG")
      ->Option.flatMap(item =>
        switch item.schema {
        | String({const}) => Some(const)
        | _ => None
        }
      )
    switch tagName {
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
  // JSON string "ItemCreated". We can use S.parseJsonOrThrow with the string.
  lookup->Dict.toArray->Array.forEach(((tagName, kind)) =>
    switch kind {
    | PayloadLess =>
      try {
        let value = JSON.String(tagName)->S.parseJsonOrThrow(schema)
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
        Some(JSON.Object(jsonDict)->S.parseJsonOrThrow(schema))
      } catch {
      | _ =>
        // A parse failure here means a stored event no longer matches the
        // current schema (drift). Dropping it silently hid real data loss;
        // surface it as a warning so it's diagnosable.
        Console.warn(
          "DcbDecode: dropped event `" ++
          eventType ++ "` — payload does not match the current schema (drift?)",
        )
        None
      }
    }

  {decode, eventTypes}
}
