/**
What a log line may not print: the values of fields marked `@pii` or `@sensitive`,
or whose semantic is a way of reaching a person (`email`, `phone`).

A log group cannot be swept for one person, so a personal value must never reach
one, as plaintext or as ciphertext. The framework's formatters see payloads as
JSON, not through their schemas, so the schemas teach this module which fields to
withhold: every payload encoded or decoded through `Util_Sury` registers its
schema once, and a formatter asks `redactJson` before it prints. A field is
withheld by name within its variant (`MemberJoined.name`), or by name in any
untagged record. Two variants of one name in two components share the set, which
withholds more, never less.

A sealed value (`{"$pii": …}`) is withheld whatever registered.
*/
/** What a withheld value prints as: no length, no hash, nothing to recover. */
let placeholder = "«pii»"

/** The bucket for records that carry no `TAG`. */
let untagged = "*"

let byVariant: dict<array<string>> = Dict.make()

let seen: WeakSet.t<S.t<unknown>> = WeakSet.make()

let add = (~variant: string, names: array<string>) =>
  if names != [] {
    let held = byVariant->Dict.get(variant)->Option.getOr([])
    byVariant->Dict.set(
      variant,
      held->Array.concat(names->Array.filter(n => !(held->Array.includes(n)))),
    )
  }

let isWithheld = (field: S.t<unknown>): bool =>
  Sensitive.isFieldSensitive(field) ||
  Pii.fieldMarker(field)->Option.isSome ||
  Semantic.getFrom(field)->Option.mapOr(false, s => Sensitive.impliedBySemantic(s.id))

let rec walk = (schema: S.t<unknown>, ~depth: int) =>
  if depth > 0 {
    switch schema {
    | AnyOf({anyOf}) => anyOf->Array.forEach(arm => walk(arm, ~depth))
    | Object({properties}) =>
      let names =
        properties
        ->Dict.toArray
        ->Array.filterMap(((name, field)) => isWithheld(field) ? Some(name) : None)
      let variant = switch properties->Dict.get("TAG") {
      | Some(String({const: ?Some(tag)})) => tag
      | _ => untagged
      }
      add(~variant, names)
      properties->Dict.valuesToArray->Array.forEach(field => walk(field, ~depth=depth - 1))
    | Array({additionalItems: Schema(item)}) => walk(item, ~depth=depth - 1)
    | _ => ()
    }
  }

/** Learn which fields of `schema`'s payloads a log line withholds. Cheap after the
    first call for a schema. */
let register = (schema: S.t<'a>): unit => {
  let schema = schema->S.castToUnknown
  if !(seen->WeakSet.has(schema)) {
    let _ = seen->WeakSet.add(schema)
    try walk(schema, ~depth=8) catch {
    | _ => ()
    }
  }
}

let withheldIn = (~variant: string): array<string> => byVariant->Dict.get(variant)->Option.getOr([])

let isSealed = (json: JSON.t): bool => json->Pii.unwrap->Option.isSome

/** `json` with every withheld value replaced by the placeholder, at any depth. */
let rec redactJson = (json: JSON.t): JSON.t =>
  switch json {
  | _ if isSealed(json) => JSON.Encode.string(placeholder)
  | Object(obj) =>
    let variant = switch obj->Dict.get("TAG") {
    | Some(String(tag)) => tag
    | _ => untagged
    }
    let withheld =
      withheldIn(~variant)->Array.concat(variant == untagged ? [] : withheldIn(~variant=untagged))
    obj
    ->Dict.toArray
    ->Array.map(((key, value)) =>
      withheld->Array.includes(key)
        ? (key, JSON.Encode.string(placeholder))
        : (key, redactJson(value))
    )
    ->Dict.fromArray
    ->JSON.Encode.object
  | Array(items) => items->Array.map(redactJson)->JSON.Encode.array
  | _ => json
  }

/**
For app code: a value as it may be logged, through its own schema. Use it in
`decide`, `project` and `translate` instead of printing a payload: whatever the
schema marks is withheld.
*/
let forLog = (value: 'a, schema: S.t<'a>): string => {
  register(schema)
  switch value->S.convertOrThrow(~from=schema, ~to=S.json) {
  | json => json->redactJson->JSON.stringify
  | exception _ => "<unencodable>"
  }
}
