module type T = {
  type sourceEvent
  type targetState

  let describe: (string, unit => unit) => unit
  let describeWithId: (string, string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Jest.assertion>) => unit

  type store = dict<array<targetState>>

  let givenEvents: array<sourceEvent> => promise<store>
  let givenEventsWithTime: array<(string, sourceEvent)> => promise<store>
  let whenEvent: (promise<store>, sourceEvent) => Jest.Expect.plainPartial<unit => promise<store>>
  let whenEvents: (
    promise<store>,
    array<sourceEvent>,
  ) => Jest.Expect.plainPartial<unit => promise<store>>
  let whenEventWithTime: (
    promise<store>,
    string,
    sourceEvent,
  ) => Jest.Expect.plainPartial<unit => promise<store>>
  let whenEventsWithTime: (
    promise<store>,
    array<(string, sourceEvent)>,
  ) => Jest.Expect.plainPartial<unit => promise<store>>
  let thenStates: (
    Jest.Expect.plainPartial<unit => promise<store>>,
    array<targetState>,
  ) => promise<Jest.assertion>
  let thenStatesWithId: (
    Jest.Expect.plainPartial<unit => promise<store>>,
    string,
    array<targetState>,
  ) => promise<Jest.assertion>
  let thenAllStates: (
    Jest.Expect.plainPartial<unit => promise<store>>,
    store,
  ) => promise<Jest.assertion>
  let thenState: (
    Jest.Expect.plainPartial<unit => promise<store>>,
    targetState,
  ) => promise<Jest.assertion>
  let thenStateWithId: (
    Jest.Expect.plainPartial<unit => promise<store>>,
    string,
    targetState,
  ) => promise<Jest.assertion>
  let thenNoState: Jest.Expect.plainPartial<unit => promise<store>> => promise<Jest.assertion>
  let thenThrow: Jest.Expect.plainPartial<unit => promise<store>> => promise<Jest.assertion>
  let thenFail: Jest.Expect.plainPartial<unit => promise<store>> => promise<Jest.assertion>
}

let unpackPlainPartial: Jest.Expect.plainPartial<'a> => 'a = p =>
  switch p {
  | #Just(unpacked) => unpacked
  }

let handleActions = Projection.handleActions // create alias to avoid shadowing of same named modules

module Make = (Projection: Reventless.Projection.Mapping): (
  T with type sourceEvent := Projection.sourceEvent and type targetState := Projection.targetState
) => {
  S.enableJson()

  let testId = ref(TestFixtures.id)
  let meta = ref(TestFixtures.meta)

  let describe = Jest.describe
  let describeWithId = (description, id, fn) => {
    testId := id
    Jest.describe(description, fn)
  }
  let test = Jest.testPromise

  type store = dict<array<Projection.targetState>>

  let getSubId = state => Projection.subIdConfig->Belt.Option.map(({getSubId}) => state->getSubId)
  let hasSubId = (state, subId) => state->getSubId->Belt.Option.getExn == subId
  let states = (store, id) => store->Dict.get(id)->Belt.Option.getWithDefault([])
  let setStates = (store, id, states) => store->Dict.set(id, states)
  let updateState = (store, id, subId, newState) =>
    store->states(id)->Belt.Array.map(state => state->hasSubId(subId) ? newState : state)
  let addState = (store, id, newState) => {
    let (updatedStates, newStates) = switch newState->getSubId {
    | Some(subId) =>
      store->states(id)->Belt.Array.some(state => state->hasSubId(subId))
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

  open Belt.Result
  //open QueryDb
  let load = (store, id) => store->states(id)->Ok->Promise.resolve
  let save = (store, id, state, saveMode: QueryDb.saveMode, _ttl) =>
    switch (store->states(id), saveMode) {
    | (_, Any)
    | ([], Init)
    | ([_], Overwrite) =>
      store->setStates(id, [state])
      Ok()->Promise.resolve
    | _ => Error(Reventless.QueryDb.StaleState)->Promise.resolve
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
    ->Array.map(event' => event'->Projection.map)
    ->handleActions({
      load: load(store, ...),
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

  open Jest.Expect
  let whenEvent = (store, event) =>
    expect(async () =>
      await (await store)->update([{Message.id: testId.contents, meta: meta.contents, event}])
    )
  let whenEvents = (store, events) =>
    expect(async () =>
      await (await store)->update(
        events->Array.map(event => {Message.id: testId.contents, meta: meta.contents, event}),
      )
    )
  let whenEventWithTime = (store, time, event) =>
    expect(async () =>
      await (await store)->update([
        {Message.id: testId.contents, meta: {...meta.contents, time}, event},
      ])
    )
  let whenEventsWithTime = (store, events) =>
    expect(async () =>
      await (await store)->update(
        events->Array.map(((time, event)) => {
          Message.id: testId.contents,
          meta: {...meta.contents, time},
          event,
        }),
      )
    )

  let thenStates = async (p, expectedStates) => {
    let store = await (p->unpackPlainPartial)()
    // Console.log2("####### store:", store)
    expect((
      store->Dict.keysToArray->Array.length,
      store->Dict.keysToArray->Array.get(0),
      store->Dict.valuesToArray->Array.get(0)->Option.getOr([]),
    ))->toEqual((1, Some(testId.contents), expectedStates))
  }
  let thenStatesWithId = async (p, id, expectedStates) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Dict.keysToArray->Array.length,
      store->Dict.keysToArray->Array.get(0),
      store->Dict.valuesToArray->Array.get(0)->Option.getOr([]),
    ))->toEqual((1, Some(id), expectedStates))
  }

  let thenAllStates = async (p, expectedStore: store) => {
    let store = await (p->unpackPlainPartial)()
    expect(store)->toEqual(expectedStore)
  }
  let thenState = async (p, expectedState) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Dict.keysToArray->Array.length,
      store->Dict.keysToArray->Array.get(0),
      store->Dict.valuesToArray->Array.get(0)->Option.getOr([])->Array.length,
      store->Dict.valuesToArray->Array.getUnsafe(0)->Array.get(0),
    ))->toEqual((1, Some(testId.contents), 1, Some(expectedState)))
  }
  let thenStateWithId = async (p, id, expectedState) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Dict.keysToArray->Array.length,
      store->Dict.keysToArray->Array.get(0),
      store->Dict.valuesToArray->Array.get(0)->Option.getOr([])->Array.length,
      store->Dict.valuesToArray->Array.getUnsafe(0)->Array.get(0),
    ))->toEqual((1, Some(id), 1, Some(expectedState)))
  }
  let thenNoState = async p => {
    let store = await (p->unpackPlainPartial)()
    expect(
      store->Dict.valuesToArray->Array.reduce(0, (acc, states) => acc + states->Array.length),
    )->toEqual(0)
  }
  let thenThrow = async p => {p->toThrow}

  let thenFail = async p =>
    switch await (p->unpackPlainPartial)() {
    | _ => Jest.fail("Expected Failure")
    | exception _ => Jest.pass
    }
}
