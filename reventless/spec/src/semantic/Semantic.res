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

/**
Which collection a value names a member of.

`field` is the collection's field name on the row — the only thing a consumer
needs, because the candidates are already loaded. `view` names the view that
collection belongs to and is absent where the answer is "the row this field is
on", which is every declaration made on a view's own state. `plugin` is absent
for the declaring plugin's own view, as everywhere else here.

Unlike `referenceTarget` this is deliberately not resolvable by query: the
members are on the row, so a consumer that went looking for a table has
misread it.

`content` names what a member *is* — an `imageRef`/`fileRef` id — and is the one
part of this that is not about the collection. It rides here for the reason
`uploadableImage` exists at all rather than `storageRef` beside a content
annotation: the collection's own element type already says it, but a consumer
holding one field's schema cannot reach a sibling's, and one that renders a cell
holds exactly that. Absent leaves the reader to its own rules, which is what a
host attaching something the vocabulary has no word for should get. */
type memberTarget = {
  view: option<string>,
  field: string,
  plugin: option<string>,
  content: option<string>,
}

/** Per-semantic detail, for the semantics that carry any. */
type payload =
  | Plain
  | ReferenceTo(referenceTarget)
  | StoredIn(storeTarget)
  | MemberOf(memberTarget)

/** A field's semantic: the vocabulary id, plus its detail. */
type t = {id: string, payload: payload}

/** The semantic ids the framework defines. These strings are the wire vocabulary
    `x-reventless-semantic` carries, shared with the annotation path. */
module Id = {
  let dateTime = "dateTime"
  // A day with no instant in it. Separate from `dateTime` because storing one as
  // an instant is what produces the midnight bug — see `CalendarDate`.
  let date = "date"
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

  // An image and the text that goes with it, in one value. Declares its store
  // the way `uploadableImage` does, on the record rather than on the reference
  // inside it, so a field reader finds it through an array wrapper.
  let captionedImage = "captionedImage"

  // A selection rather than an input: the value names a member of a collection
  // the row already holds. Declares no store, so nothing is provisioned and no
  // upload endpoint is bound — the distinction `uploadableImage` could not make.
  let memberRef = "memberRef"

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

  // The ordered record of the states a row has been through. Marks a shape
  // rather than a scalar's meaning, and rides here anyway: this is the marker
  // the schema walk emits, so anything else would be invisible on the wire.
  let lifecycleTrail = "lifecycleTrail"

  // The first composite that is a union rather than an object. Collapses fields,
  // so adopting it changes the wire and rebuilds a derived view.
  let geolocation = "geolocation"
}

/** One transparent-string semantic: a `semantic/` module whose `type t` is a
    bare `string`. */
type brandedString = {
  moduleName: string,
  /** The `Id` values of this module carry. Not derivable from the module name —
      `CalendarDate` carries `date`. */
  id: string,
  /** Whether the module exposes the `let schema` that sury-ppx resolves `X.t`
      to by convention. The `false`s build theirs from a function taking
      arguments (`forStore` / `forField` / `forCollection`), so such a field
      always carries an explicit `@s.matches` and there is no name a pass could
      derive. Offering one as a plain type pick emits code that does not
      compile. */
  hasDerivableSchema: bool,
}

/** Every transparent-string semantic, so a consumer can ask what they are
    instead of transcribing the set.

    A check written against the literal `string` keyword sees only the brand and
    refuses the field, which would make declaring a semantic cost the field
    whatever that check gates — so a pass that must leave these alone needs the
    set, not a guess. It cannot be guessed from the names: `Money.t` is a record,
    `Duration.t` an int, `Percent.t` and `Bytes.t` floats, and all four are
    deliberately absent.

    Both facts here are computable from the sources, and `SemanticBrandedStringsTest`
    recomputes them rather than trusting this list — so adding a module without
    adding it here fails, and so does the ppx's copy drifting from either. */
let brandedStrings: array<brandedString> = [
  {moduleName: "DateTime", id: Id.dateTime, hasDerivableSchema: true},
  {moduleName: "CalendarDate", id: Id.date, hasDerivableSchema: true},
  {moduleName: "Email", id: Id.email, hasDerivableSchema: true},
  {moduleName: "Phone", id: Id.phone, hasDerivableSchema: true},
  {moduleName: "Url", id: Id.url, hasDerivableSchema: true},
  {moduleName: "Color", id: Id.color, hasDerivableSchema: true},
  {moduleName: "FileRef", id: Id.fileRef, hasDerivableSchema: true},
  {moduleName: "ImageRef", id: Id.imageRef, hasDerivableSchema: true},
  {moduleName: "MemberRef", id: Id.memberRef, hasDerivableSchema: false},
  {moduleName: "StorageRef", id: Id.storageRef, hasDerivableSchema: false},
  {moduleName: "UploadableFile", id: Id.uploadableFile, hasDerivableSchema: false},
  {moduleName: "UploadableImage", id: Id.uploadableImage, hasDerivableSchema: false},
]

let semanticId: S.Metadata.Id.t<t> = S.Metadata.Id.make(~namespace="reventless", ~name="semantic")

/** Mark a schema as carrying a semantic. */
let mark = (schema: S.t<'a>, ~id: string, ~payload: payload=Plain): S.t<'a> =>
  schema->S.Metadata.set(~id=semanticId, {id, payload})

/** A schema that validates with `check` and carries the semantic `id`, derived
    from the constructor so no second grammar can drift from it. */
let // sury's refiner takes a fixed message, so `check`'s per-value reason is lost
// here; call the scalar's own `fromString`/`fromFloat` to report which rule broke.
refined = (base: S.t<'a>, ~id: string, ~check: 'a => result<'a, string>): S.t<'a> =>
  base
  ->S.refine(value =>
    switch check(value) {
    | Ok(_) => true
    | Error(_) => false
    }
  , ~error=`expected a valid ${id}`)
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
