/**
The one marker every typed semantic marks itself with.

A semantic says what a field's value *is*, as a property of its type; validation,
the wire contract and the UI widget all derive from that one declaration. One
shared marker means the schema walk reads semantics generically, so a new
semantic is a new value rather than a new branch.

The payload is a typed variant because the vocabulary is framework-owned and
closed — which also keeps `Reference.getTarget` total.
*/

/** Which entity a reference field points to. */
type referenceTarget = {entity: string, plugin: option<string>}

/** Which object store the value lives in. `plugin` is absent for the declaring
    plugin's own store; `threshold` is `@offload`'s per-field byte cut, `None`
    when it defers to the platform default. */
type storeTarget = {plugin: option<string>, store: string, threshold: option<int>}

/** Per-semantic detail, for the semantics that carry any. */
type payload =
  | Plain
  | ReferenceTo(referenceTarget)
  | StoredIn(storeTarget)

/** A field's semantic: the vocabulary id, plus its detail. */
type t = {id: string, payload: payload}

/** The semantic ids the framework defines. These strings are the wire vocabulary
    `x-reventless-semantic` carries, shared with the annotation path. */
module Id = {
  let dateTime = "dateTime"
  let reference = "reference"
  let storageRef = "storageRef"
  // Like `storageRef`, but inline-or-reference rather than always a ref path.
  let offload = "offload"

  // `storageRef` plus what the value is, so one declaration picks a renderer and
  // an upload endpoint. The ppx derives the store from the field name.
  let uploadableImage = "uploadableImage"
  let uploadableFile = "uploadableFile"

  // The same content facts with no store — nothing is provisioned.
  let imageRef = "imageRef"
  let fileRef = "fileRef"

  // Branded scalars: a refinement, so adopting one changes nothing stored.
  let email = "email"
  let phone = "phone"
  let url = "url"
  let percent = "percent"
  let bytes = "bytes"
  let duration = "duration"
  let color = "color"

  // The first composite: changes a field's shape, so it is wire-breaking.
  let money = "money"

  // A pair of ISO-8601 instants. Adopting it as a new optional field is additive.
  let dateRange = "dateRange"

  // A lat/lng pair. Cheapest to adopt: `{lat, lng}` is already the stored shape.
  let geoPoint = "geoPoint"

  // The first composite that is a union rather than an object. Collapses fields,
  // so adopting it changes the wire and rebuilds a derived view.
  let geolocation = "geolocation"
}

let semanticId: S.Metadata.Id.t<t> = S.Metadata.Id.make(~namespace="reventless", ~name="semantic")

/** Mark a schema as carrying a semantic. */
let mark = (schema: S.t<'a>, ~id: string, ~payload: payload=Plain): S.t<'a> =>
  schema->S.Metadata.set(~id=semanticId, {id, payload})

/** A schema that validates with `check` and carries the semantic `id`, derived
    from the constructor so no second grammar can drift from it. */
// sury's refiner takes a fixed message, so `check`'s per-value reason is lost
// here; call the scalar's own `fromString`/`fromFloat` to report which rule broke.
let refined = (base: S.t<'a>, ~id: string, ~check: 'a => result<'a, string>): S.t<'a> =>
  base
  ->S.refine(
    value =>
      switch check(value) {
      | Ok(_) => true
      | Error(_) => false
      },
    ~error=`expected a valid ${id}`,
  )
  ->mark(~id)

/** A value as it should read back to whoever typed it — rejection messages quote
    the offending value. */
let showString = (raw: string): string => raw->JSON.Encode.string->JSON.stringify

/**
The schema an optional field's wrapper stands for, if it is one.

sury-ppx compiles `f?: X` to a union with `Undefined`/`Null`, and that wrapper
carries no metadata of its own. Only a union with exactly one non-null variant is
followed — a real multi-variant union has no single inner schema.
*/
let unwrapOptional = (schema: S.t<unknown>): option<S.t<unknown>> =>
  switch schema {
  | AnyOf({anyOf}) =>
    switch anyOf->Array.filter(v =>
      switch v {
      | Null(_) | Undefined(_) => false
      | _ => true
      }
    ) {
    | [inner] => Some(inner)
    | _ => None
    }
  | _ => None
  }

/**
One arm of a command or event union, found by its tag.

A union with exactly one constructor is emitted as a bare object carrying the
TAG rather than a one-element `AnyOf`, so both shapes are matched.
*/
let unionVariant = (schema: S.t<unknown>, ~variant: string): option<S.t<unknown>> => {
  let isVariant = (properties: dict<S.t<unknown>>) =>
    switch properties->Dict.get("TAG") {
    | Some(String({const: ?Some(name)})) => name == variant
    | _ => false
    }
  switch schema {
  | AnyOf({anyOf}) =>
    anyOf->Array.find(arm =>
      switch arm {
      | Object({properties}) => isVariant(properties)
      | _ => false
      }
    )
  | Object({properties}) => isVariant(properties) ? Some(schema) : None
  | _ => None
  }
}

/**
The semantic a field's schema carries, if any.

An optional field keeps its marker inside the wrapper, so reading only the outer
schema loses it. The outer schema is read first, so a marker on the wrapper wins.
*/
let rec getFrom = (schema: S.t<unknown>): option<t> =>
  switch S.Metadata.get(schema, ~id=semanticId) {
  | Some(_) as found => found
  | None => schema->unwrapOptional->Option.flatMap(getFrom)
  }

let get = (fieldSchema: S.t<'a>): option<t> => fieldSchema->S.castToUnknown->getFrom

/** Whether a field's schema carries this specific semantic. */
let has = (fieldSchema: S.t<'a>, ~id: string): bool =>
  switch get(fieldSchema) {
  | Some(s) => s.id === id
  | None => false
  }
