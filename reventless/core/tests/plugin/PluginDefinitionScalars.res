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
//   `T | null` union   → null          (the `js_nullable` shape the rule asks for)
//   const / enum union → the literal
//   array              → []
//   object             → {} filled recursively
//
// A scalar arm of a nullable union is therefore not reported — but object and
// array arms are still descended, nullable or not: when an old payload happens to
// carry a nullable parent, a scalar added inside it still has to be invented.
// `requiredStoreDeclarations[].annotation`, a required string inside a nullable
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
        | Null(_) => true
        | _ => false
        }
      )
      if !isEnum {
        let nullable = has.null->Option.getOr(false)
        anyOf->Array.forEach(member =>
          switch member {
          | Null(_) => ()
          | _ if nullable && isScalar(member) => ()
          | _ => walk(member, path)
          }
        )
      }
    | _ => scalarName(schema)->Option.forEach(name => out->Array.push(`${path}: ${name}`))
    }

  walk(root, "")
  out->Array.toSorted(String.compare)
}
