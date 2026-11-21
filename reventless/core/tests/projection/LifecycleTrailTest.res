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

  // The marker is what makes a trail recognizable to a consumer holding only the
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

// The dates derived from the trail, as stored. A typed path (the builder and the
// callback both rewrite with `rewriteAction` and save through
// `QueryDb_Operations`) and the JSON path a deployed slice takes.
module OrdersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TrailOrders"
  let moduleUrl: string = %raw(`import.meta.url`)
  @schema
  type state = order
  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

module Orders = QueryDb_Operations.Make(
  OrdersSpec,
  {
    let jsonOps = QueryDbFixtures.mockJsonOps
  },
)

let derivedOf = (row: dict<JSON.t>) =>
  row
  ->Dict.toArray
  ->Array.filter(((k, _)) => k->String.startsWith("_entered_") || k->String.startsWith("_visits_"))
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

let typedStored = async (actions: array<(string, action<string, order>)>) => {
  QueryDbFixtures.reset()
  switch run(actions) {
  | Some(state) =>
    let _ = await Orders.save("o1", state, Init, None)
  | None => ()
  }
  QueryDbFixtures.store.contents
  ->Dict.get("o1")
  ->Option.flatMap(rows => rows->Array.get(0))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.mapOr([], derivedOf)
}

let jsonOrder = (state: order) =>
  state->Reventless.Util_Sury.toJson(orderSchema)->JSON.Decode.object->Option.getOrThrow

let withLifecycle = (row: JSON.t, value) =>
  switch row->JSON.Decode.object {
  | Some(d) =>
    let d = d->Dict.copy
    d->Dict.set("lifecycle", JSON.Encode.string(value))
    d->JSON.Encode.object
  | None => row
  }

let jsonStored = (actions: array<(string, action<string, JSON.t>)>) =>
  actions
  ->Array.reduce(None, (state, (at, action)) =>
    switch (
      Projection.rewriteJsonAction(action, ~at, ~stateSchema=Some(orderSchema->S.castToUnknown)),
      state,
    ) {
    | (Set(_, s), _) => Some(s)
    | (Update(_, fn), Some(s)) => Some(fn(s))
    | _ => state
    }
  )
  ->Option.flatMap(JSON.Decode.object)
  ->Option.mapOr([], derivedOf)

let s = JSON.Encode.string
let n = JSON.Encode.int

let created = [
  ("_entered_Placed", s(nine)),
  ("_entered_Placed_first", s(nine)),
  ("_entered_current", s(nine)),
  ("_visits_Placed", n(1)),
]
let shipped = [
  ("_entered_Placed", s(nine)),
  ("_entered_Placed_first", s(nine)),
  ("_entered_Shipped", s(ten)),
  ("_entered_Shipped_first", s(ten)),
  ("_entered_current", s(ten)),
  ("_visits_Placed", n(1)),
  ("_visits_Shipped", n(1)),
]
let reopened = [
  ("_entered_Cancelled", s(ten)),
  ("_entered_Cancelled_first", s(ten)),
  ("_entered_Placed", s(eleven)),
  ("_entered_Placed_first", s(nine)),
  ("_entered_current", s(eleven)),
  ("_visits_Cancelled", n(1)),
  ("_visits_Placed", n(2)),
]

describe("the dates derived from a trail, on a typed save:", () => {
  testPromise("a create", async () =>
    expect(await typedStored([(nine, Set("o1", placed))]))->toEqual(created)
  )
  testPromise("a transition", async () =>
    expect(
      await typedStored([
        (nine, Set("o1", placed)),
        (ten, Update("o1", s => {...s, lifecycle: Shipped})),
      ]),
    )->toEqual(shipped)
  )
  testPromise("a reopen keeps the first visit and counts both", async () =>
    expect(
      await typedStored([
        (nine, Set("o1", placed)),
        (ten, Update("o1", s => {...s, lifecycle: Cancelled})),
        (eleven, Update("o1", s => {...s, lifecycle: Placed})),
      ]),
    )->toEqual(reopened)
  )
  testPromise("an update that changes no state", async () =>
    expect(
      await typedStored([
        (nine, Set("o1", placed)),
        (ten, Update("o1", s => {...s, orderId: "o2"})),
      ]),
    )->toEqual(created)
  )
})

describe("the dates derived from a trail, on the JSON path:", () => {
  // Fresh per case: the JSON path rewrites the state it is handed in place.
  let placedJson = () => jsonOrder(placed)->JSON.Encode.object
  testSync("a create", () =>
    expect(jsonStored([(nine, Set("o1", placedJson()))]))->toEqual(created)
  )
  testSync("a transition", () =>
    expect(
      jsonStored([
        (nine, Set("o1", placedJson())),
        (ten, Update("o1", r => r->withLifecycle("Shipped"))),
      ]),
    )->toEqual(shipped)
  )
  testSync("a reopen keeps the first visit and counts both", () =>
    expect(
      jsonStored([
        (nine, Set("o1", placedJson())),
        (ten, Update("o1", r => r->withLifecycle("Cancelled"))),
        (eleven, Update("o1", r => r->withLifecycle("Placed"))),
      ]),
    )->toEqual(reopened)
  )
  testSync("an update that changes no state", () =>
    expect(
      jsonStored([
        (nine, Set("o1", placedJson())),
        (
          ten,
          Update(
            "o1",
            r =>
              switch r->JSON.Decode.object {
              | Some(d) =>
                let d = d->Dict.copy
                d->Dict.set("orderId", s("o2"))
                d->JSON.Encode.object
              | None => r
              },
          ),
        ),
      ]),
    )->toEqual(created)
  )
})
