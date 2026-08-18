/**
A reference to an object living in one of the platform's object stores.

The value is the ref string a store's presign service minted — an origin-relative
path rooted at the store's served prefix, which the UI renders directly because
the store is fronted read-only on the app's own origin.

## Why this is a type and not a convention

An event log is append-only, so whatever a command accepts into it is permanent.
Before this type, an `imageUrl: string` field accepted *anything* — including an
`https://` URL pointing at somebody else's server, or a multi-megabyte `data:`
URI inlined into the event itself. Both deploy green, both are unfixable after
the fact, and neither is what the field means. Declaring the field's type makes
the wrong values unrepresentable at the boundary, before `decide` ever runs.

The declaration also states a *requirement*: a field of this type says the
deployment needs a store called `store` to exist. Nothing provisions that store
yet, and that is a deliberate resting point — the validation hole is closed and
the requirement is written down, which is strictly better than the status quo
even if automatic provisioning never lands.

## The grammar

A ref is an absolute, origin-relative path of at least two non-empty segments:

    /uploads/2f8c1e94-.../photo.jpg
    /uploads/user-42/2f8c1e94-.../photo.jpg

Rejected: anything with a scheme (`https://…`, `data:…`), protocol-relative
`//host/path`, relative paths, empty segments, and `.`/`..` traversal.

The framework mints refs in exactly this form — the presign service builds the
object key as `{servedPrefix}/{identity}{uuid}/{fileName}` and returns `/{key}` —
so the grammar is the framework's to define, not an application's.

Note what is *not* checked: that the ref's prefix belongs to this specific store.
Today every store shares one served prefix, so there is nothing store-specific to
check against; the store identity is carried in the field's semantic payload,
where provisioning and the UI read it. When stores gain per-store prefixes, this
check tightens from a structural one to a per-store one without the type, the
wire format, or any stored value changing.

@example
```rescript
@schema type command =
  | ChangeProductImage({
      productId: @s.matches(DcbTag.string) string,
      imageUrl: @storageRef("productImages") string,
    })
```
*/

/** The ref's representation. Transparent `string` on purpose: the marker refines
    an existing `string` field rather than replacing it, so the field's runtime
    representation — and therefore every stored event — is unchanged. A sealed
    type here would defeat that, and would also be unattachable via `@s.matches`,
    which requires the schema's type to match the field's. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

let segmentIsSafe = (segment: string) =>
  segment !== "" && segment !== "." && segment !== ".."

/**
Validate a raw string as a storage ref, saying why when it is not one.

This is the single definition of the grammar. `forStore`'s sury schema is derived
from it rather than hand-rolling a second check, so the constructor and the
schema validation cannot drift apart.
*/
let fromString = (raw: string): result<t, string> =>
  if !String.startsWith(raw, "/") {
    Error(
      `expected an origin-relative storage ref starting with "/", got ${raw->JSON.Encode.string->JSON.stringify}. External URLs and data: URIs are not storage refs.`,
    )
  } else if String.startsWith(raw, "//") {
    Error(`protocol-relative refs are not storage refs: ${raw}`)
  } else {
    let segments = raw->String.slice(~start=1, ~end=String.length(raw))->String.split("/")
    if segments->Array.length < 2 {
      Error(`a storage ref needs a prefix and an object path, got ${raw}`)
    } else if !(segments->Array.every(segmentIsSafe)) {
      Error(`a storage ref may not contain empty or traversal segments, got ${raw}`)
    } else {
      Ok(raw)
    }
  }

/**
The refinement a ref-holding field validates against, carrying no semantic yet.
The `Uploadable*` types re-label this rather than restating the grammar, so a
re-labelling cannot validate differently from what it re-labels.
*/
// The empty string is admitted as the "no object" sentinel. The fields this
// marks are non-optional today, and a producer with nothing to reference —
// a supplier feed carrying no image, say — already writes `""` to mean
// absence. Rejecting it here would break a legitimate existing value and
// force an event-schema change, which this marker exists to avoid: it
// refines an existing `string` field without altering what is stored.
//
// Note this is a strictly weaker guarantee than `fromString`, which stays
// exact. Making these fields properly optional would let the sentinel go.
//
// sury's refiner is a predicate with a fixed message, so the per-value reason
// `fromString` returns is not threaded through; call `fromString` directly
// when the caller needs to report which rule the value broke.
let refinement: S.t<t> =
  S.string->S.refine(
    value =>
      value === "" ||
        switch fromString(value) {
        | Ok(_) => true
        | Error(_) => false
        },
    ~error=`expected an origin-relative storage ref: "/" followed by a prefix and an object path, or "" for no object`,
  )

/**
The sury schema for a field holding a ref into a named store.

Prefer the `@storageRef("<store>")` ppx shorthand over writing this by hand.
Qualify the store as `"<plugin>.<store>"` to point at another plugin's store.
*/
let forStore = (~plugin: option<string>=?, ~store: string): S.t<t> =>
  refinement->Semantic.mark(
    ~id=Semantic.Id.storageRef,
    ~payload=StoredIn({plugin, store, threshold: None}),
  )

/** The store a field's schema declares its refs live in, if any. */
let getStore = (schema: S.t<'a>): option<Semantic.storeTarget> =>
  switch Semantic.get(schema) {
  | Some({payload: StoredIn(target)}) => Some(target)
  | _ => None
  }

/** How many refs one field holds. */
type arity =
  | /** A `string` field: one ref. */ Single
  | /** An `array<string>` field: zero or more refs. */ Multiple

/**
The store a *field* declares, looking through an array wrapper, with the arity
that tells a reader how to get at the value.

`getStore` asks about a schema; this asks about a field, and those differ for
`@storageRef("s") urls: array<string>` — the ppx attaches the marker to the
element type, because `@s.matches` requires the schema's type to match what it
is attached to, so the array itself carries no marker and `getStore` on it
answers `None`.

Every reader of a *field* wants this one. Reading `getStore` directly is what
made a multi-valued store declaration invisible: the store went unprovisioned,
which is the same silence as not having written the annotation at all.
*/
let getFieldStore = (schema: S.t<'a>): option<(Semantic.storeTarget, arity)> =>
  switch getStore(schema) {
  | Some(target) => Some(target, Single)
  | None =>
    switch schema->(Obj.magic: S.t<'a> => S.t<unknown>) {
    | Array({items, additionalItems}) =>
      // sury keeps a homogeneous `S.array` element schema in `additionalItems`
      // and a tuple's positional schemas in `items`; read both so the marker is
      // found wherever the element sits.
      switch items->Array.get(0) {
      | Some(itemSchema) => getStore(itemSchema)
      | None =>
        switch additionalItems {
        | Schema(itemSchema) => getStore(itemSchema)
        | _ => None
        }
      }->Option.map(target => (target, Multiple))
    | _ => None
    }
  }
