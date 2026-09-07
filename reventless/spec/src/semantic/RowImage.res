/**
The picture a row is shown by, wherever a row is shown as a reference to it.

## Why this is derived once, here

The reference door (`{list}Refs`) names a row for a caller holding a pointer to
it, and a card or a tile that draws such a reference wants its picture for the
same reason it wants its name. Three backends answer that door — an AppSync
resolver over DynamoDB, the Postgres query Lambda, and the local GraphQL server
— and a rule about "where a row keeps its picture" spelled three times is a rule
the three would eventually disagree about. So the *field* is found once, from the
state schema, and each backend only reads it out.

## What counts as the picture

The first field, in declaration order, carrying an image semantic:
`uploadableImage` or `imageRef` (the field's value IS the ref) or
`captionedImage` (the ref sits inside the record, beside its text). A field
holding a set of them is read at `[0]`, because a set puts the primary member
first — the same member a card, a gallery tile and a list cell already draw.

Declaration order rather than a name rule: a view with two image fields has
already said which one comes first, and guessing from names would let a field
called `thumbnail` outrank the one the author put at the top.
*/

/** Where the ref string sits, relative to the field that carries it. */
type shape =
  | /** The field's own value is the ref. */ Scalar
  | /** The ref is one member of the field's record. */ Member(string)

type source = {
  field: string,
  shape: shape,
  /** The field holds a set, and the row is shown by its first member. */
  fromArray: bool,
}

/** `CaptionedImage`'s own name for the reference it wraps. Named here rather
    than spelled at each reader: the record is this package's, so a rename would
    otherwise be caught nowhere. */
let captionedImageMember = "ref"

let shapeOf = (schema: S.t<unknown>): option<shape> =>
  switch Semantic.getFrom(schema) {
  | Some({id}) if id === Semantic.Id.uploadableImage || id === Semantic.Id.imageRef => Some(Scalar)
  | Some({id}) if id === Semantic.Id.captionedImage => Some(Member(captionedImageMember))
  | _ => None
  }

// sury keeps a homogeneous element schema in `additionalItems` and a tuple's
// positional schemas in `items`; both are read, as `StorageRef.getFieldStore`
// does, so the marker is found wherever the element sits.
let elementOf = (schema: S.t<unknown>): option<S.t<unknown>> =>
  switch schema {
  | Array({items, additionalItems}) =>
    switch items->Array.get(0) {
    | Some(_) as element => element
    | None =>
      switch additionalItems {
      | Schema(element) => Some(element)
      | _ => None
      }
    }
  | _ => None
  }

let sourceOfField = (~field: string, schema: S.t<unknown>): option<source> => {
  // The marker on an optional field lives inside the wrapper, and an array's
  // lives on its element — so both are stepped through before asking.
  let unwrapped = schema->Semantic.unwrapOptional->Option.getOr(schema)
  switch shapeOf(unwrapped) {
  | Some(shape) => Some({field, shape, fromArray: false})
  | None =>
    unwrapped
    ->elementOf
    ->Option.flatMap(shapeOf)
    ->Option.map(shape => {field, shape, fromArray: true})
  }
}

/** The field a reference to this row shows it by, or nothing where the view
    declares no picture — which is most of them. */
let sourceFrom = (stateSchema: S.t<unknown>): option<source> =>
  switch stateSchema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((field, schema)) => sourceOfField(~field, schema))
    ->Array.get(0)
  | _ => None
  }

/** The ref one row carries, read out of the stored item. An empty string is read
    as absent: a projection that wrote a placeholder said nothing about a
    picture, and a consumer resolving `""` against a store gets a broken tile. */
let refFrom = (row: dict<JSON.t>, source: source): option<string> => {
  let value = row->Dict.get(source.field)
  let value = source.fromArray
    ? value->Option.flatMap(JSON.Decode.array)->Option.flatMap(members => members->Array.get(0))
    : value
  switch source.shape {
  | Scalar => value->Option.flatMap(JSON.Decode.string)
  | Member(member) =>
    value
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(d => d->Dict.get(member))
    ->Option.flatMap(JSON.Decode.string)
  }->Option.filter(ref => ref != "")
}

/** The same read as a JavaScript expression, for the one backend whose resolver
    is generated source rather than a function: the AppSync template. `null`
    where the row carries nothing, which is what the field's type promises. */
let jsExpr = (~row: string, source: source): string => {
  let at = `${row}['${source.field}']`
  let at = source.fromArray ? `(${at} ?? [])[0]` : at
  switch source.shape {
  | Scalar => `${at} ?? null`
  | Member(member) => `${at}?.['${member}'] ?? null`
  }
}
