/** Identifies which entity a reference field points to. */
type target = Semantic.referenceTarget

/**
A sury string schema annotated as an entity reference field.

Use with `@s.matches(Reference.to_("EntityName"))` on command/event fields that
carry a foreign-entity ID. Also implies DCB tag semantics so the field is
automatically queryable in DCB event logs.

Pass `~key` to override the DCB tag key (defaults to the field name). The
`@ref` ppx shorthand supplies it automatically for plural `*Ids: array<string>`
fields (singularizing, e.g. `productIds` → tag key `productId`) so they share a
tag key with their singular-named producer events.

Prefer the `@ref("EntityName")` ppx shorthand over writing `@s.matches(...)` by hand.

@example
```rescript
@schema type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      customerId: @s.matches(Reference.to_("Customer")) string,
    })
```
*/
let to_ = (~plugin=?, ~key=?, entity: string): S.t<string> => {
  // Reference-ness and DCB-tagged-ness are two independent facts that happen to
  // co-occur here: this constructor declares both. `toWithoutDcbTag` declares
  // only the first, and plain `DcbTag.string` only the second — so no consumer
  // may infer either one from the other.
  let base =
    S.string
    ->S.Metadata.set(~id=DcbTag.dcbTagId, true)
    ->Semantic.mark(~id=Semantic.Id.reference, ~payload=ReferenceTo({entity, plugin}))
  switch key {
  | Some(k) => base->S.Metadata.set(~id=DcbTag.dcbTagKeyOverrideId, k)
  | None => base
  }
}

/** Returns the reference target if the schema carries `Reference.to_(...)` metadata. */
let getTarget = (schema: S.t<unknown>): option<target> =>
  switch Semantic.get(schema) {
  | Some({payload: ReferenceTo(target)}) => Some(target)
  | _ => None
  }

/**
The entity a *field* references, wherever inside the field's type the marker sits.

`to_` returns an element schema — a `S.t<string>` — so on `@ref("E") ids:
array<string>` the ppx annotates the `string` *inside* the array and the field's
own schema carries nothing. `getTarget` answers `None` there, which is not the
same as the field declaring no reference: a consumer that finds no declared
reference falls back to a naming heuristic and resolves the field to whatever
entity the name suggests, so a dropped `@ref` is a *different* resolution rather
than a missing one. Any walk collecting a command's or event's references must
ask this question, not `getTarget`.

Only wrappers around the field's own value are followed — the optional union and
the array element, to any depth. Object properties are not: a reference declared
on a nested record's field belongs to that field, and attributing it to the
enclosing one would name the wrong field.
*/
let rec getFieldTarget = (schema: S.t<unknown>): option<target> =>
  switch getTarget(schema) {
  | Some(_) as found => found
  | None =>
    // `getTarget` already reads through the optional wrapper; the *shape* inside
    // it still has to be unwrapped here to reach an optional array's element.
    switch schema->Semantic.unwrapOptional->Option.getOr(schema) {
    | Array({additionalItems: Schema(item)}) => getFieldTarget(item)
    | _ => None
    }
  }

/**
Like `to_` but does not imply DCB tag semantics.
Use with `@ref("Entity") @noDcbTag` when the field references another entity
but should not participate in content-based event routing.
*/
let toWithoutDcbTag = (~plugin=?, entity: string): S.t<string> =>
  S.string->Semantic.mark(~id=Semantic.Id.reference, ~payload=ReferenceTo({entity, plugin}))
