// The rule that fills a lifecycle trail: an action that moves a view's
// lifecycle field appends `{state, at}`, and nothing else does. The example GWTs
// cover the same rule end to end, but their harness stamps one fixed producer
// time — the ordering-with-distinct-instants cases have to live here.

open JestGlobals
open Reventless.Projection

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type order = {
  orderId: string,
  lifecycle: lifecycle,
  trail: Reventless.Lifecycle.Trail.t<lifecycle>,
}

// A view that declares no trail, to hold the "nothing changes" case.
@schema
type plain = {
  orderId: string,
  lifecycle: lifecycle,
}

let nine = "2026-03-02T09:00:00Z"
let ten = "2026-03-02T10:00:00Z"
let eleven = "2026-03-02T11:00:00Z"

let placed = {orderId: "o1", lifecycle: Placed, trail: []}

// Applies one action to a state, the way the runtime does: `Set` writes the
// state it carries, `Update` runs its function over what is there.
let apply = (state: option<order>, action: action<string, order>): option<order> =>
  switch (action, state) {
  | (Set(_, s), _) | (Create(_, s), _) => Some(s)
  | (Update(_, fn), Some(s)) => Some(fn(s))
  | _ => state
  }

let run = (actions: array<(string, action<string, order>)>) =>
  actions->Array.reduce(None, (state, (at, action)) =>
    state->apply(Projection.rewriteAction(action, ~at, orderSchema))
  )

let statesOf = (state: option<order>) =>
  state->Option.mapOr([], s => s.trail->Array.map(entry => (entry.state, entry.at)))

describe("the lifecycle trail:", () => {
  testSync("opens with the state the row was created in", () =>
    expect(run([(nine, Set("o1", placed))])->statesOf)->toEqual([(Placed, nine)])
  )

  testSync("appends one entry per transition, in order", () =>
    expect(
      run([
        (nine, Set("o1", placed)),
        (ten, Update("o1", s => {...s, lifecycle: Shipped})),
      ])->statesOf,
    )->toEqual([(Placed, nine), (Shipped, ten)])
  )

  // The case a `dict<state, instant>` cannot hold: a reopened order is `Placed`
  // twice, at different instants, and both visits are facts about the row.
  testSync("keeps both visits when a lifecycle revisits a state", () =>
    expect(
      run([
        (nine, Set("o1", placed)),
        (ten, Update("o1", s => {...s, lifecycle: Cancelled})),
        (eleven, Update("o1", s => {...s, lifecycle: Placed})),
      ])->statesOf,
    )->toEqual([(Placed, nine), (Cancelled, ten), (Placed, eleven)])
  )

  testSync("appends nothing for an update that leaves the lifecycle alone", () =>
    expect(
      run([
        (nine, Set("o1", placed)),
        (ten, Update("o1", s => {...s, orderId: "o1-renamed"})),
      ])->statesOf,
    )->toEqual([(Placed, nine)])
  )

  // Derived from the log and the envelope's own time, so the same events in the
  // same order produce the same trail however often they are replayed.
  testSync("a rebuild from the same events produces an identical trail", () => {
    let events = [(nine, Set("o1", placed)), (ten, Update("o1", s => {...s, lifecycle: Shipped}))]
    expect(run(events)->statesOf)->toEqual(run(events)->statesOf)
  })

  // The marker is what makes a trail recognisable to a consumer holding only the
  // schema. `SchemaType.trailShape` walks the entries by shape, which skips the
  // semantic dispatch `fromSury` does, so this is the assertion that catches it
  // being dropped there — the field would still emit as a plain array of objects.
  testSync("carries the lifecycleTrail semantic onto the emitted JSON Schema", () => {
    let field =
      SuryToJsonSchema.deriveObjectSchema(~typeName="Order", orderSchema->S.castToUnknown)
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("properties"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(p => p->Dict.get("trail"))
      ->Option.flatMap(JSON.Decode.object)
    expect(field->Option.flatMap(f => f->Dict.get("x-reventless-semantic")))->toEqual(
      Some(JSON.Encode.string("lifecycleTrail")),
    )
  })

  // One vocabulary, published once: the entry's state resolves to the enum the
  // lifecycle field already emits, not a second copy under the trail's own path.
  testSync("names the entry's state after the record's own lifecycle enum", () => {
    let fields = SchemaType.fromSuryObject(~typeName="Order", orderSchema->S.castToUnknown)
    let enumName = switch fields->Option.flatMap(f => f->Dict.get("trail")) {
    | Some(Semantic(_, ArrayOf(ObjectRef(_, entry)))) =>
      switch entry->Dict.get("state") {
      | Some(Enum(name, _)) => Some(name)
      | _ => None
      }
    | _ => None
    }
    expect(enumName)->toEqual(Some("OrderLifecycle"))
  })

  testSync("a view that declares no trail is projected unchanged", () => {
    let action: action<string, plain> = Set("o1", {orderId: "o1", lifecycle: Placed})
    let rewritten = Projection.rewriteAction(action, ~at=nine, plainSchema)
    expect(
      switch rewritten {
      | Set(id, s) => Some((id, s.lifecycle))
      | _ => None
      },
    )->toEqual(Some(("o1", Placed)))
  })
})
