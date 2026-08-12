/**
Marks the field that ties a row — or a command — to the caller who owns it.

`@owner` is a *position*, not a type: it says "this field holds the id of the
principal this record belongs to". The field's nature (an entity id, a
reference) is declared separately and independently, exactly as a DCB tag and a
reference are two independent facts about one field.

Two things follow from the marker, both server-side and neither optional:

- the write path **overwrites** the field with the authenticated caller's id
  before the command is published, so an absent field and a forged field produce
  the same row; and
- reads of a view whose state carries the marker are narrowed to the caller's
  own rows, unless the caller is elevated.

Because it drives enforcement, a reader that misses the marker fails *open* —
the field goes unstamped and the view goes unscoped, silently. That is why
`fieldNames` follows the same wrappers `Reference.getFieldTarget` follows, and
why it exists at all rather than leaving each consumer to look the marker up
itself.

`@owner` is the authoring form and is sugar over the constructors below, the way
`@ref` is sugar over `Reference.to_`. Write `@s.matches(Owner.string)` by hand
only where the ppx shorthand cannot reach — a file with no `@@reventless.spec`
annotation, where the attribute would survive into the compiler as an unknown
one.

@example
```rescript
@schema type command =
  PlaceOrder({
    @partitionTag orderId: string,
    @owner customerId: string,
  })
```
*/
let ownerId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="reventless", ~name="owner")

/**
Layers the owner marker onto a schema that already says something else.

Owner-ness is independent of everything else a field declares: the same field
may be a DCB tag, a partition key, or a reference, and none of those implies or
is implied by owning. But a field carries at most one `@s.matches`, so the
shorthand composes by *wrapping* whatever schema the field already resolved to
rather than replacing it — replacing would silently drop the field's DCB tag,
and a dropped tag is a decision read that quietly misses events.
*/
let mark = (schema: S.t<'a>): S.t<'a> => schema->S.Metadata.set(~id=ownerId, true)

/** A string field declared as the record's owner. */
let string: S.t<string> = S.string->mark

/**
An `option<string>` field declared as the record's owner.

Needed because `@s.matches` on an explicitly-`option`-typed field must supply
the whole field schema, wrapper included. The `f?: string` form needs nothing
extra: sury wraps the annotated inner schema itself, and `isFieldOwner` looks
through that wrapper either way.
*/
let optionString: S.t<option<string>> = S.option(string)

/** Whether this exact schema carries the marker. Does not look through wrappers. */
let isOwner = (schema: S.t<unknown>): bool =>
  S.Metadata.get(schema, ~id=ownerId)->Option.getOr(false)

/**
Whether a *field* is the owner, wherever inside the field's type the marker sits.

An optional field keeps its marker inside the union wrapper, so a walk reading
only the outer schema answers `false` for `customerId?: string` — which for an
access-control predicate means an unscoped view rather than a reported mistake.
Object properties are deliberately not followed: a marker on a nested record's
field belongs to that field, and attributing it to the enclosing one would scope
the view on the wrong value.
*/
let isFieldOwner = (schema: S.t<unknown>): bool =>
  isOwner(schema) ||
    switch schema->Semantic.unwrapOptional {
    | Some(inner) => isOwner(inner)
    | None => false
    }

/**
The owner fields declared on an object schema, in declaration order.

Returns an array rather than an `option<string>` so the *caller* decides what a
second owner means. The structure walk rejects it; a plain reader emitting a
wire marker has no reason to.
*/
let fieldNamesOfProperties = (properties: dict<S.t<unknown>>): array<string> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((propName, propSchema)) => isFieldOwner(propSchema) ? Some(propName) : None)

let fieldNames = (schema: S.t<unknown>): array<string> =>
  switch schema {
  | Object({properties}) => fieldNamesOfProperties(properties)
  | _ => []
  }

/**
The owner fields of one constructor of a command or event union.

A command schema is a union of variants, and only the variant actually being
issued may be stamped — `PlaceOrder` and `ImportProducts` live in the same union
and have nothing to say about each other's fields. Resolving by TAG here, rather
than at the call site, is what stops a caller from stamping across variants.

Answers `[]` for an unknown tag and for a payload-less variant, both of which
mean the same thing to every caller: this command carries no owner.
*/
let variantFieldNames = (schema: S.t<unknown>, ~variant: string): array<string> => {
  let isVariant = (properties: dict<S.t<unknown>>) =>
    switch properties->Dict.get("TAG") {
    | Some(String({const: ?Some(name)})) => name == variant
    | _ => false
    }
  switch schema {
  | Union({anyOf}) =>
    anyOf
    ->Array.find(v =>
      switch v {
      | Object({properties}) => isVariant(properties)
      | _ => false
      }
    )
    ->Option.mapOr([], v =>
      switch v {
      | Object({properties}) => fieldNamesOfProperties(properties)
      | _ => []
      }
    )
  // A single-constructor command compiles to a bare object rather than a union.
  | Object({properties}) => isVariant(properties) ? fieldNamesOfProperties(properties) : []
  | _ => []
  }
}
