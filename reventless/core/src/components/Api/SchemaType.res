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
  | /** A variant used as a field: the union's name, and one arm per constructor
        keyed by the `TAG` sury discriminates on. Each arm is the `ObjectRef` its
        member type is emitted from, so the arm's own name travels with it and
        every consumer that can already render an object renders an arm.

        Only a *named* union reaches this case — see `Reventless.TaggedUnion`,
        which owns the name and the arm rules both. */
  TaggedUnion(string, array<(string, schemaType)>)
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

/**
The GraphQL type name a semantic **composite** is emitted under.

The branded scalars are absent on purpose: they refine a `string` or a number
without changing its shape, so each is already a `String` or a `Float` in GraphQL
and has no definition that could be duplicated. Only the semantics that turn a
field into an object or an enum need a name of their own — without one, the same
type is emitted once per *field* that uses it, under the field path that reached
it (`Catalog_AddProductPriceCurrency`, `Ordering_SyncNewProductPriceCurrency`, …
six copies of ISO 4217 in one example schema).

Naming them is what makes the definitions identical across plugins, which is the
property merged-API composition needs: AppSync unions same-named types from
different source APIs, and a union of identical definitions is that definition.
The `Node` / `PageInfo` / `SortOrder` base types already rely on exactly this.
*/
let semanticCompositeNames = [
  (Reventless.Semantic.Id.money, "Money"),
  (Reventless.Semantic.Id.dateRange, "DateRange"),
  (Reventless.Semantic.Id.geoPoint, "GeoPoint"),
]

let canonicalName = (id: string): option<string> =>
  semanticCompositeNames
  ->Array.find(((semanticId, _)) => semanticId == id)
  ->Option.map(((_, name)) => name)

let rec fromSury = (~parentName: string, ~fieldName: string, schema: S.t<unknown>): schemaType => {
  // Semantics the IR already has a dedicated shape for keep it: `dateTime` and
  // `reference` are read below via `isDateTime` / `getTarget`, both of which now
  // consult the generic marker, and their `format` output is a published
  // contract. Every other semantic rides along as a wrapper, so surfacing a new
  // one costs a value rather than a branch.
  switch Reventless.Semantic.get(schema) {
  | Some({id} as sem)
    if id !== Reventless.Semantic.Id.dateTime && id !== Reventless.Semantic.Id.reference =>
    // A composite is one type wherever it appears, so its shape is walked under
    // its own name rather than under the field path that reached it. That
    // renames what is nested inside it too — `Money`'s currency enum becomes
    // `MoneyCurrency` for every field, rather than one enum per price field.
    let shape = switch canonicalName(id) {
    | Some(name) => shapeOf(~parentName=name, ~fieldName="", schema)
    | None => shapeOf(~parentName, ~fieldName, schema)
    }
    Semantic(sem, shape)
  | _ => shapeOf(~parentName, ~fieldName, schema)
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
      | Some(itemSchema) => fromSury(~parentName, ~fieldName, itemSchema)
      | None =>
        // For a homogeneous S.array() sury stores the element schema in
        // additionalItems (items holds fixed tuple positions). additionalItems is
        // @unboxed: Strip="strip" | Strict="strict" | Schema(t) = the schema object.
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
    | AnyOf({anyOf}) =>
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
          // A union of payload-carrying arms. Its name is read off the schema
          // rather than composed from the field path the way the enum above is:
          // the same union is one type wherever it appears, and the write-time
          // `__typename` stamp has only the schema to derive it from.
          switch Reventless.TaggedUnion.classify(schema) {
          | Some((unionName, arms)) =>
            let armTypes = arms->Array.map(({tag, schema: armSchema}) => {
              let memberName = Reventless.TaggedUnion.memberTypeName(~union=unionName, ~arm=tag)
              let fields = Dict.make()
              switch armSchema {
              | Object({properties}) =>
                properties
                ->Dict.toArray
                ->Array.forEach(((propName, propSchema)) =>
                  if propName !== "TAG" {
                    fields->Dict.set(
                      propName,
                      fromSury(~parentName=memberName, ~fieldName=propName, propSchema),
                    )
                  }
                )
              | _ => ()
              }
              (tag, ObjectRef(memberName, fields))
            })
            let union = TaggedUnion(unionName, armTypes)
            isOptional ? Nullable(union) : union
          | None => Unknown
          }
        }
      }
    | Null(_) => Nullable(ScalarString)
    | _ => Unknown
    }
  }
}

/**
A field whose schema is a union the walk could not classify, and why.

`Unknown` is emitted as `String`, which is a lie a client only discovers at
execution time — and for a union field it is the *silent* half of a failure
whose loud half is a null in a non-nullable position. Reporting is deliberately
narrow: a field is only named here if its schema is a union of two or more real
members, which is a shape somebody wrote on purpose. An opaque `JSON.t` field
also lands on `Unknown` and is left alone, because nothing better was ever
available for it.
*/
type unclassifiedUnion = {path: string, reason: string}

// Walks the schema, not a value, so a self-referential schema has nothing to
// terminate it. Bounded rather than cycle-detected: this is a report, and a
// field nested a dozen records deep is past the depth the SDL emitter itself
// renders usefully.
let maxReportDepth = 12

let rec collectUnclassifiedUnions = (
  ~path: string,
  ~depth: int=0,
  schema: S.t<unknown>,
  out: array<unclassifiedUnion>,
): unit =>
  if depth > maxReportDepth {
    ()
  } else {
    let under = (name: string) => path === "" ? name : path ++ "." ++ name
    let recurse = (~path, schema) => collectUnclassifiedUnions(~path, ~depth=depth + 1, schema, out)
    switch schema {
    | Object({properties}) =>
      properties
      ->Dict.toArray
      ->Array.forEach(((name, propSchema)) =>
        if name !== "TAG" {
          recurse(~path=under(name), propSchema)
        }
      )
    | Array({items, additionalItems}) =>
      let itemSchema = switch items->Array.get(0) {
      | Some(s) => Some(s)
      | None =>
        switch additionalItems {
        | Schema(s) => Some(s)
        | _ => None
        }
      }
      switch itemSchema {
      | Some(s) => recurse(~path=path ++ "[]", s)
      | None => ()
      }
    | AnyOf({anyOf}) =>
      let members = anyOf->Array.filter(v =>
        switch v {
        | Null(_) | Undefined(_) => false
        | _ => true
        }
      )
      switch members {
      | [inner] => recurse(~path, inner)
      | _ =>
        let allConst = members->Array.every(v =>
          switch v {
          | String({const: ?Some(_)}) => true
          | _ => false
          }
        )
        if allConst {
          ()
        } else {
          switch Reventless.TaggedUnion.classify(schema) {
          | Some((_, arms)) =>
            arms->Array.forEach(({tag, schema: armSchema}) => recurse(~path=under(tag), armSchema))
          | None =>
            let reason = if Reventless.TaggedUnion.armsOf(schema)->Option.isSome {
              `its arms are well-formed but the union carries no name. Declare it in a spec file, where the ppx names it, or mark the schema with \`Reventless.TaggedUnion.named\`.`
            } else {
              `its ${members
                ->Array.length
                ->Int.toString} members are neither all string literals (an enum) nor all tagged objects each declaring at least one named field of its own (a union).`
            }
            out->Array.push({path, reason})
          }
        }
      }
    | _ => ()
    }
  }

let unclassifiedUnions = (schema: S.t<unknown>): array<unclassifiedUnion> => {
  let out = []
  collectUnclassifiedUnions(~path="", schema, out)
  out
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
      | AnyOf({anyOf}) =>
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
