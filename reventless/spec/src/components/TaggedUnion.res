/**
A variant used as a **field** of a queryable's state — one fact with several
shapes, rather than several fields that have to be kept in step by hand.

```rescript
@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({point: Reventless.GeoPoint.t})
  | Unresolvable({reason: string})
```

The value is stored the way sury encodes it — `{"TAG":"Located","point":{…}}` —
and reaches GraphQL as a union of one object type per arm. Both halves need the
*same* name for the union, and neither can derive it from the other: the SDL
emitter walks a schema it reaches through a field path, and the write path has
only the schema in hand. So the name is carried **on the schema**, set once at
the declaration by `named` — the ppx does it for a variant a state record uses,
and a framework type carrying a union does it beside its `Semantic.mark`.

A union with no name is not emitted as one. It falls through to the IR's
`Unknown`, which is a `String` in the SDL — the behaviour that predates this
module — except that it is now reported at deploy time instead of silently.
*/
let unionNameId: S.Metadata.Id.t<string> = S.Metadata.Id.make(
  ~namespace="reventless",
  ~name="taggedUnionName",
)

/**
Names a union, so that the type emitted for it and the `__typename` stamped into
every stored value of it agree.

Written at the declaration, never at the field: two fields holding the same union
hold the same type, and naming it per field is what produces one GraphQL type per
field path — the mistake `semanticCompositeNames` exists to undo for `Money`.
*/
let named = (~name: string, schema: S.t<'a>): S.t<'a> =>
  schema->S.Metadata.set(~id=unionNameId, name)

/**
The name a union field's schema carries.

Read straight off the field's schema, wrapper included: sury's `option` keeps the
metadata of what it wraps, which matters because it does *not* keep the union as
a nested schema — `option<t>` flattens the arms and the `undefined` into one
`anyOf`, leaving nothing inside to consult. `TaggedUnionTest` pins that, since a
sury release that stopped preserving it would turn every optional union field
into a `String` with no compile error anywhere.
*/
let getName = (schema: S.t<unknown>): option<string> => S.Metadata.get(schema, ~id=unionNameId)

/**
The GraphQL type emitted for one arm: the union's name with the arm's own
appended (`Geolocation` + `Located` = `GeolocationLocated`).

One derivation, used by the SDL emitter and by the write-time stamp. A second
spelling of this rule anywhere is a `__typename` that resolves to no member,
which GraphQL reports as a null — and a null in a non-nullable field takes its
parent with it.
*/
let memberTypeName = (~union: string, ~arm: string): string => union ++ arm

/** The key a stored union value carries its member type under. */
let typenameKey = "__typename"

/** One arm: the constructor name sury writes into `TAG`, and the arm's schema. */
type arm = {tag: string, schema: S.t<unknown>}

// A payload sury named rather than the author: `| Located(GeoPoint.t)` encodes to
// `{"TAG":"Located","_0":{…}}`, and `_0` would be published as an SDL field name
// and as a stored key. The ppx refuses the shape at its declaration; this refuses
// it again for a union declared where the ppx cannot see it, by declining to
// classify the union at all.
let isPositionalName = (name: string): bool =>
  name->String.startsWith("_") &&
  name->String.length > 1 &&
  name
  ->String.slice(~start=1, ~end=name->String.length)
  ->String.split("")
  ->Array.every(c => c >= "0" && c <= "9")

/**
The arms of a schema that is a union of tagged objects, or `None`.

Refuses three shapes, all for reasons that are GraphQL's rather than sury's, and
all of which encode and decode perfectly well:

- a payload-less arm (`| Pending`), which sury writes as the bare string
  `"Pending"` — a union member must be an object type;
- an arm with no field of its own (`| Pending({})`), which would imply a member
  type with zero fields;
- a positional payload, whose field name is the compiler's `_0`.

Declining leaves the field an `Unknown`, which is reported where it is emitted.
*/
let armsOf = (schema: S.t<unknown>): option<array<arm>> =>
  switch schema {
  | AnyOf({anyOf}) =>
    let members = anyOf->Array.filter(v =>
      switch v {
      | Null(_) | Undefined(_) => false
      | _ => true
      }
    )
    if members->Array.length < 2 {
      None
    } else {
      let arms = members->Array.filterMap(member =>
        switch member {
        | Object({properties}) =>
          switch properties->Dict.get("TAG") {
          | Some(String({const: ?Some(tag)})) =>
            let fields = properties->Dict.toArray->Array.filter(((name, _)) => name !== "TAG")
            if (
              fields->Array.length == 0 ||
                fields->Array.some(((name, _)) => isPositionalName(name))
            ) {
              None
            } else {
              Some({tag, schema: member})
            }
          | _ => None
          }
        | _ => None
        }
      )
      arms->Array.length == members->Array.length ? Some(arms) : None
    }
  | _ => None
  }

/** A named union of tagged objects: its name and its arms, or `None`. */
let classify = (schema: S.t<unknown>): option<(string, array<arm>)> =>
  switch (getName(schema), armsOf(schema)) {
  | (Some(name), Some(arms)) => Some((name, arms))
  | _ => None
  }

/**
Whether a schema is a union of tagged objects that carries no name — the one case
worth telling a deploy about, since it is a union the author meant and the SDL
cannot emit.
*/
let isUnnamedUnion = (schema: S.t<unknown>): bool =>
  getName(schema)->Option.isNone && armsOf(schema)->Option.isSome

/**
Stamps `__typename` into every union value inside an encoded row, in place.

Written once at save rather than by each read door: both AppSync and graphql-js
resolve a union member from `__typename` on the value they are handed, and the
AppSync resolvers hand back the stored item unchanged. The doors that would each
have to stamp number fourteen across three backends, and the live change channel
— which carries the row as raw JSON, past the typed field entirely — is reachable
from none of them. Stamping here is one place, and it is the only one both
channels share.

Driven by the schema, so a row of a view with no union field is walked and left
byte-identical.
*/
let rec stampInto = (~schema: S.t<unknown>, json: JSON.t): unit =>
  switch classify(schema) {
  | Some((name, arms)) =>
    switch json->JSON.Decode.object {
    | Some(obj) =>
      switch obj->Dict.get("TAG")->Option.flatMap(JSON.Decode.string) {
      | Some(tag) =>
        obj->Dict.set(typenameKey, JSON.Encode.string(memberTypeName(~union=name, ~arm=tag)))
        // An arm's own fields may hold unions too, so the arm is walked as the
        // record it is — the union case above cannot recurse into it, since a
        // union's schema says nothing about which arm this value took.
        switch arms->Array.find(a => a.tag === tag) {
        | Some({schema: armSchema}) => stampMembers(~schema=armSchema, json)
        | None => ()
        }
      | None => ()
      }
    | None => ()
    }
  | None => stampMembers(~schema, json)
  }

and stampMembers = (~schema: S.t<unknown>, json: JSON.t): unit =>
  switch schema {
  | Object({properties}) =>
    switch json->JSON.Decode.object {
    | Some(obj) =>
      properties
      ->Dict.toArray
      ->Array.forEach(((name, propSchema)) =>
        switch obj->Dict.get(name) {
        | Some(value) => stampInto(~schema=propSchema, value)
        | None => ()
        }
      )
    | None => ()
    }
  | Array({items, additionalItems}) =>
    let itemSchema = switch items->Array.get(0) {
    | Some(itemSchema) => Some(itemSchema)
    | None =>
      switch additionalItems {
      | Schema(s) => Some(s)
      | _ => None
      }
    }
    switch (itemSchema, json->JSON.Decode.array) {
    | (Some(itemSchema), Some(values)) =>
      values->Array.forEach(value => stampInto(~schema=itemSchema, value))
    | _ => ()
    }
  | _ =>
    // An optional field wraps its schema in a union with `undefined`; the value
    // that reached us is the inner one either way.
    switch Semantic.unwrapOptional(schema) {
    | Some(inner) => stampInto(~schema=inner, json)
    | None => ()
    }
  }

/**
The union fields an object schema declares, named and unnamed alike, with the
name where there is one.

The SDL emitter and the deploy-time report both need to say *which field* — a
report that names only the view leaves the author grepping.
*/
let fieldsOf = (schema: S.t<unknown>): array<(string, option<string>)> =>
  switch schema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((name, propSchema)) =>
      armsOf(propSchema)->Option.isSome ? Some((name, getName(propSchema))) : None
    )
  | _ => []
  }
