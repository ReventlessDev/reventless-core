type rec schemaType =
  | ScalarString
  | ScalarNumber
  | ScalarBoolean
  | ScalarBigInt
  | EntityId
  | DateTime
  | Nullable(schemaType)
  | ArrayOf(schemaType)
  | ObjectRef(string, dict<schemaType>)
  | Enum(string, array<string>)
  | /** A field whose type carries a semantic the IR has no dedicated shape for.
        Wraps the shape the value actually has, so every consumer that only cares
        about shape unwraps and is otherwise unaffected. `DateTime` and `EntityId`
        are *not* expressed this way: they long predate the generic marker and
        their JSON Schema `format` output is a published contract. */
  Semantic(Reventless.Semantic.t, schemaType)
  | Unknown

let isTagged = Reventless.DcbTag.isTagged
let isDateTime = Reventless.DateTime.isDateTime

let isIdFieldName = (name: string): bool => {
  let lower = String.toLowerCase(name)
  let len = String.length(lower)
  len > 2 && String.endsWith(lower, "id")
}

let isIdsFieldName = (name: string): bool => {
  let lower = String.toLowerCase(name)
  let len = String.length(lower)
  len > 3 && String.endsWith(lower, "ids")
}

let rec fromSury = (~parentName: string, ~fieldName: string, schema: S.t<unknown>): schemaType => {
  let shape = shapeOf(~parentName, ~fieldName, schema)
  // Semantics the IR already has a dedicated shape for keep it: `dateTime` and
  // `reference` are read below via `isDateTime` / `getTarget`, both of which now
  // consult the generic marker, and their `format` output is a published
  // contract. Every other semantic rides along as a wrapper, so surfacing a new
  // one costs a value rather than a branch.
  switch Reventless.Semantic.get(schema) {
  | Some({id} as sem)
    if id !== Reventless.Semantic.Id.dateTime && id !== Reventless.Semantic.Id.reference =>
    Semantic(sem, shape)
  | _ => shape
  }
}

and shapeOf = (~parentName: string, ~fieldName: string, schema: S.t<unknown>): schemaType => {
  // Two independent facts, checked independently. A DCB-tagged field is an
  // entity id because it routes; a reference field is one because it points at
  // an entity. Neither implies the other — a `@partitionTag` field carries no
  // reference, and `Reference.toWithoutDcbTag` carries no tag — so collapsing
  // these into one test would silently reclassify whichever case it dropped.
  if isTagged(schema) || Reventless.Reference.getTarget(schema)->Option.isSome {
    EntityId
  } else {
    switch schema {
    | String({const: ?Some(_)}) => ScalarString
    | String(_) if isDateTime(schema) => DateTime
    | String(_) => isIdFieldName(fieldName) ? EntityId : ScalarString
    | Number(_) => ScalarNumber
    | Boolean(_) => ScalarBoolean
    | BigInt(_) => ScalarBigInt
    | Array({items, additionalItems}) =>
      let itemType = switch items->Array.get(0) {
      | Some({schema: itemSchema}) =>
        fromSury(
          ~parentName,
          ~fieldName,
          itemSchema->(Obj.magic: S.t<unknown> => S.t<unknown>),
        )
      | None =>
        // sury stores the item schema in additionalItems (not items) for S.array().
        // additionalItems is @unboxed: Strip="strip", Strict="strict", Schema(t) = the schema object.
        switch additionalItems {
        | Schema(s) => fromSury(~parentName, ~fieldName, s)
        | _ => ScalarString
        }
      }
      let itemType = (isIdsFieldName(fieldName) || isIdFieldName(fieldName)) && itemType == ScalarString
        ? EntityId
        : itemType
      ArrayOf(itemType)
    | Object({properties}) =>
      let nestedName =
        parentName ++
        fieldName->String.charAt(0)->String.toUpperCase ++
        fieldName->String.slice(~start=1, ~end=fieldName->String.length)
      let fields = Dict.make()
      properties
      ->Dict.toArray
      ->Array.forEach(((propName, propSchema)) => {
        if propName !== "TAG" {
          fields->Dict.set(propName, fromSury(~parentName=nestedName, ~fieldName=propName, propSchema))
        }
      })
      if fields->Dict.keysToArray->Array.length == 0 {
        Unknown
      } else {
        ObjectRef(nestedName, fields)
      }
    | Union({anyOf}) =>
      let nonNullVariants = anyOf->Array.filter(v =>
        switch v {
        | Null(_) | Undefined(_) => false
        | _ => true
        }
      )
      let isOptional = nonNullVariants->Array.length < anyOf->Array.length
      if nonNullVariants->Array.length == 1 {
        Nullable(
          fromSury(
            ~parentName,
            ~fieldName,
            nonNullVariants->Array.getUnsafe(0),
          ),
        )
      } else {
        let constValues = nonNullVariants->Array.filterMap(v =>
          switch v {
          | String({const: ?Some(c)}) => Some(c)
          | _ => None
          }
        )
        if constValues->Array.length == nonNullVariants->Array.length && constValues->Array.length > 0 {
          let enumName =
            parentName ++
            fieldName->String.charAt(0)->String.toUpperCase ++
            fieldName->String.slice(~start=1, ~end=fieldName->String.length)
          let enum = Enum(enumName, constValues)
          isOptional ? Nullable(enum) : enum
        } else {
          Unknown
        }
      }
    | Null(_) => Nullable(ScalarString)
    | _ => Unknown
    }
  }
}

/**
The names of an object's optional properties, read from sury rather than from
the IR.

The IR cannot answer this for every field. `shapeOf` classifies a DCB-tagged or
`@ref` field as `EntityId` before it ever looks at the union sury wraps an
`option<…>` in — correctly, since those markers now describe the field through
that wrapper — so an optional reference reaches the IR as a plain `EntityId`
with its optionality spent. Asking the source schema keeps the two questions
apart: what a field *is*, and whether it has to be there.

Top-level properties only. A nested object's own fields are emitted by the
`ObjectRef` branch, which has no `required` of its own today.
*/
let optionalFieldNames = (schema: S.t<unknown>): array<string> =>
  switch schema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((propName, propSchema)) =>
      switch propSchema {
      | Union({anyOf}) =>
        anyOf->Array.some(v =>
          switch v {
          | Null(_) | Undefined(_) => true
          | _ => false
          }
        )
          ? Some(propName)
          : None
      | _ => None
      }
    )
  | _ => []
  }

let fromSuryObject = (~typeName: string, schema: S.t<unknown>): option<dict<schemaType>> =>
  switch schema {
  | Object({properties}) =>
    let fields = Dict.make()
    properties
    ->Dict.toArray
    ->Array.forEach(((propName, propSchema)) => {
      if propName !== "TAG" {
        fields->Dict.set(propName, fromSury(~parentName=typeName, ~fieldName=propName, propSchema))
      }
    })
    Some(fields)
  | _ => None
  }
