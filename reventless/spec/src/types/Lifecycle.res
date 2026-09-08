/**
Where a record's lifecycle lives, and the trail of states it has been through.

`fieldName` is the single rule for which field holds a lifecycle — every
consumer resolves it here rather than restating it. `Trail` is the one field a
view declares to have each state it reaches recorded with the instant it was
reached; the projection machinery fills it, not the domain.
*/

// A wire enum: a union whose non-null members are all string constants. A
// tagged union's members are objects, so the same test excludes it.
let isEnumSchema = (schema: S.t<unknown>): bool =>
  switch schema {
  | AnyOf({anyOf}) =>
    let members = anyOf->Array.filter(v =>
      switch v {
      | Null(_) | Undefined(_) => false
      | _ => true
      }
    )
    members->Array.length > 0 &&
      members->Array.every(v =>
        switch v {
        | String({const: ?Some(_)}) => true
        | _ => false
        }
      )
  | _ => false
  }

// A semantic or a DCB tag makes the field an instant, an id or a reference
// before it is ever an enum — the order `SchemaType.fromSury` resolves in.
let isLifecycleShape = (schema: S.t<unknown>): bool =>
  Semantic.get(schema)->Option.isNone && !DcbTag.isTagged(schema) && isEnumSchema(schema)

/**
The field holding a record's lifecycle: `@lifecycle`, else an enum field
literally named `lifecycle`. Not keyed on `status`, a name that would guess.
*/
let fieldName = (stateSchema: S.t<unknown>): option<string> =>
  switch StateAnnotations.getSpec(stateSchema) {
  | Some({lifecycle: Some(_) as annotated}) => annotated
  | _ =>
    switch stateSchema {
    | Object({properties}) =>
      properties
      ->Dict.get("lifecycle")
      ->Option.flatMap(schema => isLifecycleShape(schema) ? Some("lifecycle") : None)
    | _ => None
    }
  }

/**
The ordered record of the states a row has been through.

Ordered rather than keyed by state because a lifecycle revisits states — a
reopened order is `Placed` twice, and a map has to choose which visit to keep.
A state the row never reached has no entry; there is no value to invent for it.
*/
module Trail = {
  /** One state the row entered, and the instant it did. */
  @schema
  type entry<'state> = {
    state: 'state,
    at: DateTime.t,
    /** First entry after a span the cap dropped. Absent while trails are kept
        whole; declared now so capping later is not a contract change. */
    afterGap?: bool,
  }

  type t<'state> = array<entry<'state>>

  /** The schema for a trail field. Resolved by sury-ppx from the declared type
      `Reventless.Lifecycle.Trail.t<lifecycle>`, so a view writes no annotation.

      Marked with the shared semantic rather than a metadata id of its own: that
      marker is the one the JSON Schema walk emits, so a private id would leave
      the trail indistinguishable on the wire from any other array of objects —
      and a consumer reduced to matching a field called `trail` by name. */
  let schema = (stateSchema: S.t<'state>): S.t<t<'state>> =>
    S.array(entrySchema(stateSchema))->Semantic.mark(~id=Semantic.Id.lifecycleTrail)

  let isTrail = (schema: S.t<unknown>): bool =>
    Semantic.has(schema, ~id=Semantic.Id.lifecycleTrail)

  /** The trail field declared on a state record, if it declares one. */
  let fieldName = (stateSchema: S.t<unknown>): option<string> =>
    switch stateSchema {
    | Object({properties}) =>
      properties
      ->Dict.toArray
      ->Array.find(((_, schema)) => isTrail(schema))
      ->Option.map(((name, _)) => name)
    | _ => None
    }

  /** Append `{state, at}` to the trail a state's JSON holds at `field`. */
  let record = (stateDict: dict<JSON.t>, ~field: string, ~state: JSON.t, ~at: string): unit => {
    let entries = switch stateDict->Dict.get(field) {
    | Some(Array(existing)) => existing
    | _ => []
    }
    let entry = Dict.fromArray([("state", state), ("at", JSON.Encode.string(at))])
    stateDict->Dict.set(field, entries->Array.concat([entry->JSON.Encode.object])->JSON.Encode.array)
  }
}
