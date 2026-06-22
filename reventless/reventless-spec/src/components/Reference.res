/** Identifies which entity a reference field points to. */
type target = {entity: string, plugin: option<string>}

/** Sury metadata ID for entity reference annotation. */
let referenceId: S.Metadata.Id.t<target> = S.Metadata.Id.make(~namespace="reventless", ~name="reference")

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
  let base =
    S.string
    ->S.Metadata.set(~id=DcbTag.dcbTagId, true)
    ->S.Metadata.set(~id=referenceId, {entity, plugin})
  switch key {
  | Some(k) => base->S.Metadata.set(~id=DcbTag.dcbTagKeyOverrideId, k)
  | None => base
  }
}

/** Returns the reference target if the schema carries `Reference.to_(...)` metadata. */
let getTarget = (schema: S.t<unknown>): option<target> =>
  S.Metadata.get(schema, ~id=referenceId)

/**
Like `to_` but does not imply DCB tag semantics.
Use with `@ref("Entity") @noDcbTag` when the field references another entity
but should not participate in content-based event routing.
*/
let toWithoutDcbTag = (~plugin=?, entity: string): S.t<string> =>
  S.string->S.Metadata.set(~id=referenceId, {entity, plugin})
