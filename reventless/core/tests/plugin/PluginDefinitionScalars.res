// Collects every bare required scalar reachable from a sury schema.
//
// Walks sury's own tagged variant (`@tag("type") type t<'value>`), the same way
// `SchemaType.fromSury` does — so a change to sury's schema surface is a compile
// error here rather than a walker that silently returns nothing. That matters
// more than usual for this one: it backs a guard whose only job is to fail at
// the right moment, and a guard that quietly collects `[]` passes while checking
// nothing.
//
// A scalar is "bare required" when `Message.fillMissingDefaults` could not supply
// a value for it from the schema alone. Everything else it CAN supply is skipped:
//
//   optional union     → absent        (the `option` shape the rule asks for —
//                                       `T | undefined`, or legacy `T | null`)
//   const / enum union → the literal
//   array              → []
//   object             → {} filled recursively
//
// A scalar arm of an optional union is therefore not reported — but object and
// array arms are still descended, optional or not: when an old payload happens to
// carry an optional parent, a scalar added inside it still has to be invented.
// `requiredStoreDeclarations[].annotation`, a required string inside an optional
// array, is exactly that case and is how a plugin's registration once froze.

let scalarName = (schema: S.t<unknown>): option<string> =>
  switch schema {
  | String({const: ?None}) => Some("string")
  | Number({const: ?None}) => Some("number")
  | Boolean({const: ?None}) => Some("boolean")
  | BigInt({const: ?None}) => Some("bigint")
  | _ => None
  }

let isScalar = (schema: S.t<unknown>): bool => scalarName(schema)->Option.isSome

let collect = (root: S.t<'a>): array<string> => {
  let root = root->S.castToUnknown
  let out = []
  // Guards against a self-referential schema. Identity, not structure: sury
  // shares one object per schema, so a cycle revisits the same reference.
  let seen: Set.t<S.t<unknown>> = Set.make()

  let rec walk = (schema: S.t<unknown>, path: string) =>
    switch schema {
    | Object({properties}) =>
      if !(seen->Set.has(schema)) {
        seen->Set.add(schema)
        properties
        ->Dict.toArray
        ->Array.forEach(((name, fieldSchema)) => walk(fieldSchema, `${path}.${name}`))
        seen->Set.delete(schema)->ignore
      }
    | Array({additionalItems: Schema(element)}) => walk(element, `${path}[]`)
    | AnyOf({anyOf, has}) =>
      // A union of literals is an enum: absent heals to the first variant.
      let isEnum = anyOf->Array.every(member =>
        switch member {
        | String({const: ?Some(_)})
        | Number({const: ?Some(_)})
        | Boolean({const: ?Some(_)})
        | BigInt({const: ?Some(_)})
        | Undefined(_)
        | Null(_) => true
        | _ => false
        }
      )
      if !isEnum {
        // Either optional encoding: the healer leaves an absent `T | undefined`
        // alone and writes `null` for a `T | null`, so neither invents a scalar.
        let optional =
          has.null->Option.getOr(false) || has.undefined->Option.getOr(false)
        anyOf->Array.forEach(member =>
          switch member {
          | Undefined(_) | Null(_) => ()
          | _ if optional && isScalar(member) => ()
          | _ => walk(member, path)
          }
        )
      }
    | _ => scalarName(schema)->Option.forEach(name => out->Array.push(`${path}: ${name}`))
    }

  walk(root, "")
  out->Array.toSorted(String.compare)
}
