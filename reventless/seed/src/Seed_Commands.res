// A generated adapter: turns a mutation's name and its arguments as JSON into a
// `mutation`, rendered by the types the domain API publishes about itself.
//
// It reads the API's introspection, which any caller who may send commands may
// read, and which covers every mutation, inbound translations included. It only
// produces `mutation` values: they are sent like any other.

open Seed_Types

type rec typeRef = Named(string) | NonNull(typeRef) | ListOf(typeRef)

type input = {name: string, typ: typeRef, hasDefault: bool}

type kind =
  | Scalar
  | EnumOf(array<string>)
  | InputObject(array<input>)
  | Other

type t = {mutations: dict<array<input>>, kinds: dict<kind>}

let typeRefFragment = `fragment TypeRef on __Type {
  kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } }
}`

let introspectionQuery = `${typeRefFragment}
query {
  __schema {
    mutationType { name }
    types {
      kind name
      enumValues { name }
      inputFields { name defaultValue type { ...TypeRef } }
      fields { name args { name defaultValue type { ...TypeRef } } }
    }
  }
}`

// ── Reading the introspection ───────────────────────────────────────────────

let get = (json: JSON.t, key: string): option<JSON.t> =>
  switch json {
  | Object(d) => d->Dict.get(key)
  | _ => None
  }

let str = (json: JSON.t, key: string): option<string> =>
  switch json->get(key) {
  | Some(String(s)) => Some(s)
  | _ => None
  }

let items = (json: JSON.t, key: string): array<JSON.t> =>
  switch json->get(key) {
  | Some(Array(xs)) => xs
  | _ => []
  }

let rec typeRefOf = (json: JSON.t): typeRef => {
  let inner = () => json->get("ofType")->Option.mapOr(Named("?"), typeRefOf)
  switch json->str("kind") {
  | Some("NON_NULL") => NonNull(inner())
  | Some("LIST") => ListOf(inner())
  | _ => Named(json->str("name")->Option.getOr("?"))
  }
}

let inputOf = (json: JSON.t): input => {
  name: json->str("name")->Option.getOr(""),
  typ: json->get("type")->Option.mapOr(Named("?"), typeRefOf),
  hasDefault: switch json->get("defaultValue") {
  | Some(String(_)) => true
  | _ => false
  },
}

/** Reads an introspection result: the `data` of `introspectionQuery`, or what
    `graphql`'s `introspectionFromSchema` returns. */
let fromIntrospection = (data: JSON.t): t => {
  let schema = data->get("__schema")->Option.getOr(JSON.Encode.null)
  let mutationType =
    schema->get("mutationType")->Option.flatMap(m => m->str("name"))->Option.getOr("Mutation")
  let kinds = Dict.make()
  let mutations = Dict.make()
  schema
  ->items("types")
  ->Array.forEach(ty => {
    let name = ty->str("name")->Option.getOr("")
    let kind = switch ty->str("kind") {
    | Some("SCALAR") => Scalar
    | Some("ENUM") => EnumOf(ty->items("enumValues")->Array.filterMap(v => v->str("name")))
    | Some("INPUT_OBJECT") => InputObject(ty->items("inputFields")->Array.map(inputOf))
    | _ => Other
    }
    kinds->Dict.set(name, kind)
    if name == mutationType {
      ty
      ->items("fields")
      ->Array.forEach(f =>
        mutations->Dict.set(f->str("name")->Option.getOr(""), f->items("args")->Array.map(inputOf))
      )
    }
  })
  {mutations, kinds}
}

/** Reads the domain API's description of itself, once per run. */
let fetch = async (client: Seed_Client.t): t =>
  fromIntrospection(
    await client->Seed_Client.gql(~query=introspectionQuery, ~label="introspection"),
  )

// ── Encoding ────────────────────────────────────────────────────────────────

let rec typeName = (typ: typeRef): string =>
  switch typ {
  | Named(n) => n
  | NonNull(inner) => `${typeName(inner)}!`
  | ListOf(inner) => `[${typeName(inner)}]`
  }

let isRequired = (i: input): bool =>
  switch i.typ {
  | NonNull(_) => !i.hasDefault
  | _ => false
  }

let rec valueOf = (s: t, typ: typeRef, json: JSON.t, ~path: string): result<
  option<value>,
  string,
> =>
  switch (typ, json) {
  | (NonNull(_), Null) => Error(`${path}: required, got null`)
  | (NonNull(inner), _) => valueOf(s, inner, json, ~path)
  | (_, Null) => Ok(None)
  | (ListOf(inner), Array(xs)) =>
    xs
    ->Array.mapWithIndex((x, i) => valueOf(s, inner, x, ~path=`${path}[${i->Int.toString}]`))
    ->Array.reduce(Ok([]), (acc, r) =>
      switch (acc, r) {
      | (Error(e), _) | (_, Error(e)) => Error(e)
      | (Ok(vs), Ok(Some(v))) => Ok(vs->Array.concat([v]))
      | (Ok(_), Ok(None)) => Error(`${path}: a list item is null`)
      }
    )
    ->Result.map(vs => Some(List(vs)))
  | (ListOf(_), _) => Error(`${path}: expected a list`)
  | (Named(name), _) =>
    switch (s.kinds->Dict.get(name), json) {
    | (Some(EnumOf(values)), String(v)) if values->Array.includes(v) => Ok(Some(Enum(v)))
    | (Some(EnumOf(values)), _) =>
      Error(`${path}: expected one of ${values->Array.join(", ")}, got ${JSON.stringify(json)}`)
    | (Some(InputObject(fields)), Object(d)) =>
      argsOf(s, fields, d, ~path)->Result.map(fs => Some(Object(fs)))
    | (Some(InputObject(_)), _) => Error(`${path}: expected an object of type ${name}`)
    | (_, String(v)) if name == "ID" => Ok(Some(Id(v)))
    | (_, Number(n)) if name == "ID" => Ok(Some(Id(n->Float.toString)))
    | (_, Number(n)) if name == "Int" && Math.floor(n) == n => Ok(Some(Int(n->Float.toInt)))
    | (_, Number(n)) if name == "Float" => Ok(Some(Float(n)))
    | (_, Boolean(b)) if name == "Boolean" => Ok(Some(Bool(b)))
    | (Some(Scalar), String(v)) if !(["Int", "Float", "Boolean"]->Array.includes(name)) =>
      Ok(Some(String(v)))
    | _ => Error(`${path}: ${JSON.stringify(json)} is not a ${name}`)
    }
  }

and argsOf = (s: t, inputs: array<input>, given: dict<JSON.t>, ~path: string): result<
  array<(string, value)>,
  string,
> => {
  let unknown = given->Dict.keysToArray->Array.filter(k => !(inputs->Array.some(i => i.name == k)))
  let missing = inputs->Array.filter(i => isRequired(i) && given->Dict.get(i.name)->Option.isNone)
  switch (unknown[0], missing[0]) {
  | (Some(k), _) =>
    Error(`${path}: no argument "${k}" (has: ${inputs->Array.map(i => i.name)->Array.join(", ")})`)
  | (_, Some(i)) => Error(`${path}: "${i.name}" (${typeName(i.typ)}) is required`)
  | _ =>
    given
    ->Dict.toArray
    ->Array.reduce(Ok([]), (acc, (k, json)) =>
      switch acc {
      | Error(_) => acc
      | Ok(args) =>
        switch inputs->Array.find(i => i.name == k) {
        | None => acc
        | Some(i) =>
          valueOf(s, i.typ, json, ~path=`${path}.${k}`)->Result.map(v =>
            switch v {
            | Some(v) => args->Array.concat([(k, v)])
            | None => args
            }
          )
        }
      }
    )
  }
}

/**
 * The mutation `field` called with `args`, an object of its arguments, each
 * rendered as its declared type says: an enum unquoted, an input object nested.
 * An argument the field does not take, a required one left out, or a value of
 * the wrong type is an error naming it, before anything is sent.
 */
let encode = (s: t, ~field: string, args: JSON.t): result<mutation, string> =>
  switch (s.mutations->Dict.get(field), args) {
  | (None, _) => Error(`the API has no mutation "${field}"`)
  | (Some(inputs), Object(d)) =>
    argsOf(s, inputs, d, ~path=field)->Result.map(args => Seed_Types.mutation(field, args))
  | (Some(_), _) => Error(`${field}: the arguments must be an object`)
  }

let encodeOrThrow = (s: t, ~field: string, args: JSON.t): mutation =>
  switch encode(s, ~field, args) {
  | Ok(m) => m
  | Error(message) => throw(Failed(message))
  }

/**
 * Whether `body` is what the mutation `field` takes, as a JSON body: what a
 * webhook door of an inbound translation is posted. Every inbound translation has
 * a mutation whose arguments are its external input's fields, so the API's own
 * description checks the body a door will read, before it is sent.
 */
let checkBody = (s: t, ~field: string, body: JSON.t): result<unit, string> =>
  encode(s, ~field, body)->Result.map(_ => ())
