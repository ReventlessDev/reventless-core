/**
An image the platform stores, together with the text that goes with it.

## Why the text travels with the reference

A picture and the words that describe it are one thing, and holding them apart is
what let them drift. A view that carried an image field and a caption field
beside it had to keep the pair in step on every arm of its projection, and the
one arm that forgot produced a hero image with no alternative text — an
accessibility hole opened by a projection, not by a missing command.

Inside one value there is no pair to keep in step. It also puts the text where a
renderer can reach it: a cell renderer is handed a field's key, its schema and
its value, and never the row — so a caption in a *sibling field* is a caption no
cell can draw.

## Two texts, not one

They are different things and one does not substitute for the other.
**`altText` replaces** the image: what a screen reader announces instead of it,
what shows when it fails to load. **`caption` sits beside** it, visible to
everyone. `altText: "Blue running shoe, side profile"` and
`caption: "Front view"` are both correct and neither does the other's job.

A consumer resolves them like this, and the rules are written down because a
wrong one is silent:

- **the visible caption** is `caption` only. Absent means no visible text.
- **`alt`** is `altText`, else `caption`, else `""`.

The fallback through `caption` is deliberate and slightly impure. The pure rule —
`altText` else `""` — makes a host that filled only `caption` emit `alt=""` on
every photo, which declares them decorative. An imperfect accessible name is
better than a wrong one.

## No store argument on the field

The store is the host field's name, pluralised, derived by the ppx exactly as it
is for {!UploadableImage} — and the rule is idempotent, so `productImages:
array<CaptionedImage.t>` and `categoryImage?: CaptionedImage.t` both derive the
store their host means. The marker lands on this record rather than on the `ref`
inside it, which is what lets `StorageRef.getFieldStore` find the store through
an array wrapper without looking a level deeper.

## A pair, not a general type

Monomorphic on purpose: the ppx matches the *spelling* of a field's type under an
empty type-argument list, so an `Attachment.t<'ref>` would not match and no store
would be derived — silently. A document counterpart is a second type for the
reason {!UploadableImage} and {!UploadableFile} are two: they differ in what the
value depicts, not in how a reference to it is written. It would carry no
`altText`, because a document has no visual to replace.

@example
```rescript
@schema type state = {
  productId: string,
  productImages: array<Reventless.CaptionedImage.t>,
}
```
*/

/** The record itself. No `@schema`: the derived schema would have to name a
    store, and the store is the host field's — so `forField` is the only way to
    a schema, and a field the ppx did not reach fails to compile rather than
    provisioning a store nobody meant. */
type t = {
  ref: UploadableImage.t,
  altText?: string,
  caption?: string,
}

/**
The sury schema for a field holding captioned images out of a named store.

Prefer typing the field `CaptionedImage.t` (or `array<CaptionedImage.t>`) and
letting the ppx call this. Written by hand it needs the derived store name, which
defeats the point of the type.
*/
let forField = (~plugin: option<string>=?, ~store: string): S.t<t> =>
  S.schema(s => {
    ref: s.matches(UploadableImage.forField(~plugin?, ~store)),
    altText: ?s.matches(S.option(S.string)),
    caption: ?s.matches(S.option(S.string)),
  })->Semantic.mark(
    ~id=Semantic.Id.captionedImage,
    // The store rides on the record, not on `ref`: a field reader looks through
    // an optional wrapper and an array element and no further, so a marker one
    // record deeper would be a store declaration nothing provisions.
    ~payload=StoredIn({plugin, store, threshold: None}),
  )

/** The text that replaces the image, by the rule above — `altText`, else the
    caption, else nothing. One definition, because a second one would be the
    drift this type exists to remove. */
let altTextOf = (c: t): option<string> =>
  switch c.altText {
  | Some(_) as text => text
  | None => c.caption
  }
