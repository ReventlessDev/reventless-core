open ReventlessCore

// Plan 02 — single-source projection GWT for StateViewSlice (and any future
// single-source projection target). Promoted from the legacy
// `StateViewSlice_GWT` so the DSL name now matches the implementation kind
// emitted by the PPX (`Projection_GWT.Make(Spec, X_Projection)`).
//
// Multi-source ReadModel projections (the `FooProjections.res + Mapping.Make`
// pattern) live in `MultiSourceProjection_GWT` — same DSL surface, different
// source description.

// Minimal inline Spec — mirrors `Reventless.StateViewSlice.Spec` minus the
// fields the GWT DSL doesn't read (`config`). Declared inline so sury-ppx
// processes `@schema` in this compilation unit.
module type Spec = {
  let name: string

  @schema
  type state

  let stateSchema: S.t<state>

  @schema
  type consumedEvent

  let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>>
}

// Implementation half — one binding (`project`).
module type Projection = {
  module Spec: Spec

  let project: Reventless.StateViewSlice.consumed<Spec.consumedEvent> => array<
    Reventless.Projection.action<string, Spec.state>,
  >
}

module type T = {
  module Spec: Spec

  let describe: (string, unit => unit) => unit
  let describeWithId: (string, string, unit => unit) => unit
  let todo: string => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit

  type store = dict<array<Spec.state>>
  type storeThunk = unit => promise<store>

  let givenEvents: array<Spec.consumedEvent> => promise<store>
  let whenEvent: (promise<store>, Spec.consumedEvent) => storeThunk
  let whenEvents: (promise<store>, array<Spec.consumedEvent>) => storeThunk
  let thenStates: (storeThunk, array<Spec.state>) => promise<Outcome.outcome>
  let thenStatesWithId: (storeThunk, string, array<Spec.state>) => promise<Outcome.outcome>
  let thenAllStates: (storeThunk, store) => promise<Outcome.outcome>
  let thenState: (storeThunk, Spec.state) => promise<Outcome.outcome>
  let thenStateWithId: (storeThunk, string, Spec.state) => promise<Outcome.outcome>
  let thenNoState: storeThunk => promise<Outcome.outcome>
  let thenThrow: storeThunk => promise<Outcome.outcome>
  let thenFail: storeThunk => promise<Outcome.outcome>
}

let handleActions = Projection.handleActions // local alias to avoid shadowing

module Make = (
  Spec: Spec,
  Projection: Projection with module Spec := Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let testId = ref(TestFixtures.id)

  let describe = JestBind.describe
  let todo = JestBind.todo
  let describeWithId = (description, id, fn) => {
    testId := id
    JestBind.describe(description, fn)
  }
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=Spec.name, name, ~timeout?, body)

  type store = dict<array<Spec.state>>
  type storeThunk = unit => promise<store>

  let getSubId = state => Spec.subIdConfig->Option.map(({getSubId}) => state->getSubId)
  let hasSubId = (state, subId) => state->getSubId->Option.getOrThrow == subId
  let states = (store, id) => store->Dict.get(id)->Option.getOr([])
  let setStates = (store, id, states) => store->Dict.set(id, states)
  let updateState = (store, id, subId, newState) =>
    store->states(id)->Array.map(state => state->hasSubId(subId) ? newState : state)
  let addState = (store, id, newState) => {
    let (updatedStates, newStates) = switch newState->getSubId {
    | Some(subId) =>
      store->states(id)->Array.some(state => state->hasSubId(subId))
        ? (store->updateState(id, subId, newState), [])
        : (store->states(id), [newState])
    | None => (store->states(id), [newState])
    }
    store->Dict.set(id, Array.concat(updatedStates, newStates))
  }
  let deleteStates = (store, id) => store->Dict.set(id, [])
  let deleteSubState = (store, id, subId, getSubId) =>
    store->Dict.set(
      id,
      store
      ->Dict.get(id)
      ->Option.map(states => states->Array.filter(state => state->getSubId != subId))
      ->Option.getOr([]),
    )

  let load = (store, id) => store->states(id)->Ok->Promise.resolve
  let save = (store, id, state, saveMode: QueryDb.saveMode, _ttl) =>
    switch (store->states(id), saveMode, Spec.subIdConfig) {
    | (_, Any, Some(_))
    | (_, Init, Some(_)) =>
      store->addState(id, state)
      Ok()->Promise.resolve
    | (_, Any, None)
    | ([], Init, _)
    | ([_], Overwrite, _) =>
      store->setStates(id, [state])
      Ok()->Promise.resolve
    | _ => Error(ReventlessInfra.QueryDb.StaleState)->Promise.resolve
    }
  let saveBatch = (store, batch) => {
    batch->Array.forEach(((id, state, _ttl)) => store->addState(id, state))
    Ok()->Promise.resolve
  }
  let delete = (store, id, subId) =>
    switch (subId, Spec.subIdConfig) {
    | (None, _) =>
      store->deleteStates(id)
      Ok()->Promise.resolve
    | (Some((_, subId)), Some({Reventless.ReadModel.getSubId: getSubId})) =>
      store->deleteSubState(id, subId, getSubId)
      Ok()->Promise.resolve
    | _ => Ok()->Promise.resolve
    }
  let deleteBatch = (store, ids) => {
    ids->Array.forEach(((id, subId)) =>
      switch (subId, Spec.subIdConfig) {
      | (None, _) => store->deleteStates(id)
      | (Some((_, subId)), Some({Reventless.ReadModel.getSubId: getSubId})) =>
        store->deleteSubState(id, subId, getSubId)
      | _ => ()
      }
    )
    Ok()->Promise.resolve
  }

  let runActions = (actions, operations) =>
    actions->handleActions(operations, Spec.subIdConfig)

  let sortStore = store =>
    switch Spec.subIdConfig {
    | None => store
    | Some(_) =>
      Dict.mapValues(store, states =>
        states->Array.toSorted((s1, s2) =>
          String.compare(s1->getSubId->Option.getUnsafe, s2->getSubId->Option.getUnsafe)
        )
      )
    }

  let update = async (store, events) => {
    // Projection.project produces an array of actions per event — flatten and
    // feed them through handleActions against the dict store. Each bare event is
    // wrapped in the `consumed` envelope with the deterministic test `meta` /
    // `recordedAt` so a projection reading `meta.time` asserts a fixed value.
    let actions =
      events
      ->Array.map(ev =>
        {
          Reventless.StateViewSlice.event: ev,
          meta: TestFixtures.meta,
          recordedAt: TestFixtures.recordedAt,
        }->Projection.project
      )
      ->Array.flat
    await actions->runActions({
      load: load(store, ...),
      loadStream: id => store->states(id)->Stream.fromIterable,
      save: save(store, ...),
      saveBatch: saveBatch(store, ...),
      count: async (_, _, _) => Ok(0),
      delete: delete(store, ...),
      deleteBatch: deleteBatch(store, ...),
    })

    store->sortStore
  }

  let givenEvents = events => Dict.make()->update(events)

  let whenEvent = (store, event): storeThunk =>
    () => (async () => await (await store)->update([event]))()
  let whenEvents = (store, events): storeThunk =>
    () => (async () => await (await store)->update(events))()

  let encState = (s: Spec.state) => s->Message.encode(Spec.stateSchema)
  let encStates = (arr: array<Spec.state>) => arr->Array.map(encState)

  let stateEq = (a: Spec.state, b: Spec.state) =>
    JSON.stringify(encState(a)) == JSON.stringify(encState(b))
  let statesEq = (a, b) =>
    Array.length(a) == Array.length(b) &&
      Array.zip(a, b)->Array.every(((x, y)) => stateEq(x, y))
  let storeEq = (a: store, b: store) => {
    let ka = a->Dict.keysToArray->Array.toSorted(String.compare)
    let kb = b->Dict.keysToArray->Array.toSorted(String.compare)
    ka == kb &&
      ka->Array.every(key =>
        statesEq(a->Dict.get(key)->Option.getOr([]), b->Dict.get(key)->Option.getOr([]))
      )
  }

  let encStore = (s: store) => {
    let obj = Dict.make()
    s
    ->Dict.toArray
    ->Array.forEach(((k, v)) => obj->Dict.set(k, JSON.Encode.array(v->encStates)))
    JSON.Encode.object(obj)
  }

  let thenStates = async (thunk, expectedStates) => {
    let store = await thunk()
    let keys = store->Dict.keysToArray
    let actualId = keys->Array.get(0)
    let actualStates = store->Dict.valuesToArray->Array.get(0)->Option.getOr([])
    if (
      keys->Array.length == 1 &&
        actualId == Some(testId.contents) &&
        statesEq(actualStates, expectedStates)
    ) {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: testId.contents,
          expected: Some(JSON.Encode.array(expectedStates->encStates)),
          actual: Some(encStore(store)),
        }),
      )
    }
  }

  let thenStatesWithId = async (thunk, id, expectedStates) => {
    let store = await thunk()
    let keys = store->Dict.keysToArray
    let actualId = keys->Array.get(0)
    let actualStates = store->Dict.valuesToArray->Array.get(0)->Option.getOr([])
    if keys->Array.length == 1 && actualId == Some(id) && statesEq(actualStates, expectedStates) {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: id,
          expected: Some(JSON.Encode.array(expectedStates->encStates)),
          actual: Some(encStore(store)),
        }),
      )
    }
  }

  let thenAllStates = async (thunk, expectedStore: store) => {
    let store = await thunk()
    if storeEq(store, expectedStore) {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: "<all>",
          expected: Some(encStore(expectedStore)),
          actual: Some(encStore(store)),
        }),
      )
    }
  }

  let thenState = (thunk, expectedState) => thenStates(thunk, [expectedState])
  let thenStateWithId = (thunk, id, expectedState) =>
    thenStatesWithId(thunk, id, [expectedState])

  let thenNoState = async thunk => {
    let store = await thunk()
    let total =
      store->Dict.valuesToArray->Array.reduce(0, (acc, states) => acc + states->Array.length)
    if total == 0 {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: "<any>",
          expected: None,
          actual: Some(encStore(store)),
        }),
      )
    }
  }

  let thenThrow = async thunk =>
    switch await thunk() {
    | _ =>
      Outcome.fail(
        Throw({
          error: "Expected thunk to throw but it returned normally",
          stack: "",
        }),
      )
    | exception _ => Outcome.pass
    }

  let thenFail = async thunk =>
    switch await thunk() {
    | _ =>
      Outcome.fail(
        Throw({error: "Expected failure but thunk returned normally", stack: ""}),
      )
    | exception _ => Outcome.pass
    }
}
