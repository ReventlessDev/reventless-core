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
type referenceTarget = {entity: string, plugin: option<string>, identity?: string}

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
  /** Which identity an id is: named by its key (`orderId`). */
  | IdentityOf({key: string})

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

  // Which entity an id names, carried by the type `Id.Make` produces. A string on
  // the wire, so adopting one changes nothing stored.
  let identity = "identity"
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
  /** A value the module accepts, as the string itself (not as source): a tool
      writes it as a string literal. An obvious example, never plausible data,
      because a new scenario starts from it. For the modules without a derivable
      schema it is a value their schema accepts for any store or collection. */
  sample: string,
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
  {
    moduleName: "DateTime",
    id: Id.dateTime,
    hasDerivableSchema: true,
    sample: "2024-01-01T00:00:00Z",
  },
  {moduleName: "CalendarDate", id: Id.date, hasDerivableSchema: true, sample: "2024-01-01"},
  {moduleName: "Email", id: Id.email, hasDerivableSchema: true, sample: "ada@example.com"},
  // 555-0100…0199 is the North American range reserved for fiction.
  {moduleName: "Phone", id: Id.phone, hasDerivableSchema: true, sample: "+15555550100"},
  {moduleName: "Url", id: Id.url, hasDerivableSchema: true, sample: "https://example.com"},
  {moduleName: "Color", id: Id.color, hasDerivableSchema: true, sample: "#1e90ff"},
  {
    moduleName: "FileRef",
    id: Id.fileRef,
    hasDerivableSchema: true,
    sample: "https://example.com/example.pdf",
  },
  {
    moduleName: "ImageRef",
    id: Id.imageRef,
    hasDerivableSchema: true,
    sample: "https://example.com/example.png",
  },
  {
    moduleName: "MemberRef",
    id: Id.memberRef,
    hasDerivableSchema: false,
    sample: "/example/example.png",
  },
  {
    moduleName: "StorageRef",
    id: Id.storageRef,
    hasDerivableSchema: false,
    sample: "/example/example.txt",
  },
  {
    moduleName: "UploadableFile",
    id: Id.uploadableFile,
    hasDerivableSchema: false,
    sample: "/example/example.pdf",
  },
  {
    moduleName: "UploadableImage",
    id: Id.uploadableImage,
    hasDerivableSchema: false,
    sample: "/example/example.png",
  },
]

/** How a value of a `valueType` is put together, so a tool can offer an input
    that fits it. */
type valueShape =
  /** A number literal. `integer` says whether it is written `3600` or `50.0` —
      a float field does not accept an int literal. */
  | Number({integer: bool})
  /** One of a closed set of codes, each written as the module's constructor. */
  | Codes({codes: array<string>})
  /** A value built from named parts: `(part, module or primitive)`. A module
      names another `semantic/` module (its `sample` fills the part); a primitive
      is `float`, `int` or `string`. */
  | Parts({parts: array<(string, string)>})

/** A semantic whose value is not a bare string: how to write one. */
type valueType = {
  moduleName: string,
  shape: valueShape,
  /** A value, written as ReScript source, fully qualified: what a tool emits.
      An obvious example, never plausible data. */
  sample: string,
  /** How to write one. `$part` is replaced by that part's source: the module's
      constructor where it returns `t` (`Money.make`), a record literal where the
      constructor returns `result`, since a test value should not need
      unwrapping. A `Number` has the one part `$value`, a `Codes` the one part
      `$code`. */
  writer: string,
}

/** Every semantic whose `type t` is not a bare string and which types a field a
    scenario fills. The type names cannot say how to write one — `Money.t` is a
    record, `Duration.t` an int — so a tool reads it here instead of guessing.

    `SemanticValueTypesTest` compiles every sample, runs it through its module's
    schema, and checks `Currency`'s codes against `Currency.all`. */
let valueTypes: array<valueType> = [
  {
    moduleName: "Money",
    shape: Parts({parts: [("amount", "float"), ("currency", "Currency")]}),
    // Whole minor units: 1000 is 10.00 EUR.
    sample: "Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR)",
    writer: "Reventless.Money.make(~amount=$amount, ~currency=$currency)",
  },
  {
    moduleName: "Currency",
    shape: Codes({codes: Currency.all->Array.map(Currency.toString)}),
    sample: "Reventless.Currency.EUR",
    writer: "Reventless.Currency.$code",
  },
  {
    moduleName: "DateRange",
    shape: Parts({parts: [("start", "DateTime"), ("end_", "DateTime")]}),
    sample: `{Reventless.DateRange.start: "2024-01-01T00:00:00Z", end_: "2024-01-02T00:00:00Z"}`,
    writer: "{Reventless.DateRange.start: $start, end_: $end_}",
  },
  {
    moduleName: "GeoPoint",
    shape: Parts({parts: [("lat", "float"), ("lng", "float")]}),
    sample: "{Reventless.GeoPoint.lat: 0.0, lng: 0.0}",
    writer: "{Reventless.GeoPoint.lat: $lat, lng: $lng}",
  },
  {
    moduleName: "CaptionedImage",
    // `altText` and `caption` are optional fields; the writer gives both.
    shape: Parts({
      parts: [("ref", "UploadableImage"), ("altText", "string"), ("caption", "string")],
    }),
    sample: `{Reventless.CaptionedImage.ref: "/example/example.png", altText: "An example image", caption: "An example caption"}`,
    writer: "{Reventless.CaptionedImage.ref: $ref, altText: $altText, caption: $caption}",
  },
  {
    moduleName: "Duration",
    shape: Number({integer: true}),
    // Seconds: one hour.
    sample: "3600",
    writer: "$value",
  },
  {moduleName: "Percent", shape: Number({integer: false}), sample: "50.0", writer: "$value"},
  {moduleName: "Bytes", shape: Number({integer: false}), sample: "1024.0", writer: "$value"},
]

/** `semantic/` modules whose `type t` types a field, but whose shape
    `valueShape` cannot express yet. `Geolocation.t` is a union of cases with
    payloads. A tool asks for its value as ReScript source. */
let valueTypesWithoutWriter: array<string> = ["Geolocation"]

/** `semantic/` modules that are not a field's value: capabilities, helpers and
    wrappers the ppx applies. Listed so the coverage test can tell a forgotten
    module from a deliberate omission. */
let nonValueModules: array<string> = [
  "Capabilities",
  "CapabilityNeed",
  "Geocoding",
  "IdentityProvider",
  "Media_Ref",
  "Messaging",
  "Offload",
  "RowImage",
  "Secrets",
  "Semantic",
  "Template",
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

/** The identity a field's value is (`orderId`), read through `option<…>`. A
    reference to an identity carries it on its target, since a schema holds one
    semantic. */
let identityKey = (fieldSchema: S.t<'a>): option<string> =>
  switch get(fieldSchema) {
  | Some({payload: IdentityOf({key})}) => Some(key)
  | Some({payload: ReferenceTo({?identity})}) => identity
  | _ => None
  }

/** The identity a field names, on its own value or on an array's elements. */
let rec fieldIdentityKey = (fieldSchema: S.t<unknown>): option<string> =>
  switch identityKey(fieldSchema) {
  | Some(_) as found => found
  | None =>
    switch fieldSchema->unwrapOptional->Option.getOr(fieldSchema) {
    | Array({additionalItems: Schema(item)}) => fieldIdentityKey(item)
    | _ => None
    }
  }

/** Whether a field's schema carries this specific semantic. */
let has = (fieldSchema: S.t<'a>, ~id: string): bool =>
  switch get(fieldSchema) {
  | Some(s) => s.id === id
  | None => false
  }
