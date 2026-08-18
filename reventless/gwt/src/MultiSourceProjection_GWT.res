open ReventlessCore

module type T = {
  type sourceEvent
  type targetState

  let describe: (string, unit => unit) => unit
  let describeWithId: (string, string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit

  type store = dict<array<targetState>>
  type storeThunk = unit => promise<store>

  let givenEvents: array<sourceEvent> => promise<store>
  let givenEventsWithTime: array<(string, sourceEvent)> => promise<store>
  let whenEvent: (promise<store>, sourceEvent) => storeThunk
  let whenEvents: (promise<store>, array<sourceEvent>) => storeThunk
  let whenEventWithTime: (promise<store>, string, sourceEvent) => storeThunk
  let whenEventsWithTime: (promise<store>, array<(string, sourceEvent)>) => storeThunk
  let thenStates: (storeThunk, array<targetState>) => promise<Outcome.outcome>
  let thenStatesWithId: (storeThunk, string, array<targetState>) => promise<Outcome.outcome>
  let thenAllStates: (storeThunk, store) => promise<Outcome.outcome>
  let thenState: (storeThunk, targetState) => promise<Outcome.outcome>
  let thenStateWithId: (storeThunk, string, targetState) => promise<Outcome.outcome>
  let thenNoState: storeThunk => promise<Outcome.outcome>
  let thenThrow: storeThunk => promise<Outcome.outcome>
  let thenFail: storeThunk => promise<Outcome.outcome>
}

let handleActions = Projection.handleActions // create alias to avoid shadowing of same named modules

module Make = (Projection: Reventless.Projection.Mapping): (
  T with type sourceEvent := Projection.sourceEvent and type targetState := Projection.targetState
) => {

  let testId = ref(TestFixtures.id)
  let meta = ref(TestFixtures.meta)

  let describe = JestBind.describe
  let describeWithId = (description, id, fn) => {
    testId := id
    JestBind.describe(description, fn)
  }
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=Projection.sourceName, name, ~timeout?, body)

  type store = dict<array<Projection.targetState>>
  type storeThunk = unit => promise<store>

  let getSubId = state => Projection.subIdConfig->Option.map(({getSubId}) => state->getSubId)
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
    switch (store->states(id), saveMode) {
    | (_, Any)
    | ([], Init)
    | ([_], Overwrite) =>
      store->setStates(id, [state])
      Ok()->Promise.resolve
    | _ => Error(ReventlessInfra.QueryDb.StaleState)->Promise.resolve
    }
  let saveBatch = (store, batch) => {
    batch->Array.forEach(((id, state, _ttl)) => store->addState(id, state))
    Ok()->Promise.resolve
  }
  let delete = (store, id, subId) =>
    switch (subId, Projection.subIdConfig) {
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
      switch (subId, Projection.subIdConfig) {
      | (None, _) => store->deleteStates(id)
      | (Some((_, subId)), Some({Reventless.ReadModel.getSubId: getSubId})) =>
        store->deleteSubState(id, subId, getSubId)
      | _ => ()
      }
    )
    Ok()->Promise.resolve
  }

  let handleActions = (actions, operations) =>
    actions->handleActions(operations, Projection.subIdConfig)

  let sortStore = store =>
    switch Projection.subIdConfig {
    | None => store
    | Some(_) =>
      Dict.mapValues(store, states =>
        states->Array.toSorted((state1, state2) =>
          String.compare(state1->getSubId->Option.getUnsafe, state2->getSubId->Option.getUnsafe)
        )
      )
    }

  let update = async (store, events') => {
    await events'
    ->Array.map(event' => event'->Projection.project)
    ->handleActions({
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

  let givenEvents = events =>
    Dict.make()->update(
      events->Array.map(event => {Message.id: testId.contents, meta: meta.contents, event}),
    )

  let givenEventsWithTime = events =>
    Dict.make()->update(
      events->Array.map(((time, event)) => {
        Message.id: testId.contents,
        meta: {...meta.contents, time},
        event,
      }),
    )

  let whenEvent = (store, event): storeThunk =>
    () =>
      (
        async () =>
          await (await store)->update([{Message.id: testId.contents, meta: meta.contents, event}])
      )()
  let whenEvents = (store, events): storeThunk =>
    () =>
      (
        async () =>
          await (await store)->update(
            events->Array.map(event => {Message.id: testId.contents, meta: meta.contents, event}),
          )
      )()
  let whenEventWithTime = (store, time, event): storeThunk =>
    () =>
      (
        async () =>
          await (await store)->update([
            {Message.id: testId.contents, meta: {...meta.contents, time}, event},
          ])
      )()
  let whenEventsWithTime = (store, events): storeThunk =>
    () =>
      (
        async () =>
          await (await store)->update(
            events->Array.map(((time, event)) => {
              Message.id: testId.contents,
              meta: {...meta.contents, time},
              event,
            }),
          )
      )()

  let encState = (s: Projection.targetState) => s->Message.encode(Projection.targetStateSchema)
  let encStates = (arr: array<Projection.targetState>) => arr->Array.map(encState)

  // State equality via encoded JSON — handles ReScript structural comparison
  // nuances when states contain types whose `==` is not meaningful.
  let stateEq = (a: Projection.targetState, b: Projection.targetState) =>
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
