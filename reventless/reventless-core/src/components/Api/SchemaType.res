type rec schemaType =
  | ScalarString
  | ScalarNumber
  | ScalarBoolean
  | ScalarBigInt
  | EntityId
  | Nullable(schemaType)
  | ArrayOf(schemaType)
  | ObjectRef(string, dict<schemaType>)
  | Enum(string, array<string>)
  | Unknown

let isTagged = Reventless.DcbTag.isTagged

let rec fromSury = (~parentName: string, ~fieldName: string, schema: S.t<unknown>): schemaType => {
  if isTagged(schema) {
    EntityId
  } else {
    switch schema {
    | String({const: ?Some(_)}) => ScalarString
    | String(_) => ScalarString
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
      ObjectRef(nestedName, fields)
    | Union({anyOf}) =>
      let nonNullVariants = anyOf->Array.filter(v =>
        switch v {
        | Null(_) => false
        | _ => true
        }
      )
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
          Enum(enumName, constValues)
        } else {
          Unknown
        }
      }
    | Null(_) => Nullable(ScalarString)
    | _ => Unknown
    }
  }
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
