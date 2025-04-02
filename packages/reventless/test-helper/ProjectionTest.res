module type T = {
  type sourceEvent
  type targetState
  //module Source: ReventlessSpec.Projection.Spec.Source
  //module Target: ReventlessSpec.Projection.Spec.Target

  let describe: (string, unit => unit) => unit
  let describeWithId: (string, string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => Js.Promise.t<Jest.assertion>) => unit

  type store = Js.Dict.t<array<targetState>>

  let givenEvents: array<sourceEvent> => Js.Promise.t<store>
  let givenEventsWithTime: array<(string, sourceEvent)> => Js.Promise.t<store>
  let whenEvent: (
    Js.Promise.t<store>,
    sourceEvent,
  ) => Jest.Expect.plainPartial<unit => Js.Promise.t<store>>
  let whenEventWithTime: (
    Js.Promise.t<store>,
    string,
    sourceEvent,
  ) => Jest.Expect.plainPartial<unit => Js.Promise.t<store>>
  let thenStates: (
    Jest.Expect.plainPartial<unit => Js.Promise.t<store>>,
    array<targetState>,
  ) => Js.Promise.t<Jest.assertion>
  let thenStatesWithId: (
    Jest.Expect.plainPartial<unit => Js.Promise.t<store>>,
    string,
    array<targetState>,
  ) => Js.Promise.t<Jest.assertion>
  let thenAllStates: (
    Jest.Expect.plainPartial<unit => Js.Promise.t<store>>,
    store,
  ) => Js.Promise.t<Jest.assertion>
  let thenState: (
    Jest.Expect.plainPartial<unit => Js.Promise.t<store>>,
    targetState,
  ) => Js.Promise.t<Jest.assertion>
  let thenStateWithId: (
    Jest.Expect.plainPartial<unit => Js.Promise.t<store>>,
    string,
    targetState,
  ) => Js.Promise.t<Jest.assertion>
  let thenNoState: Jest.Expect.plainPartial<unit => Js.Promise.t<store>> => Js.Promise.t<
    Jest.assertion,
  >
  let thenThrow: Jest.Expect.plainPartial<unit => Js.Promise.t<store>> => Js.Promise.t<
    Jest.assertion,
  >
  let thenFail: Jest.Expect.plainPartial<unit => Js.Promise.t<store>> => Js.Promise.t<
    Jest.assertion,
  >
}

let unpackPlainPartial: Jest.Expect.plainPartial<'a> => 'a = p =>
  switch p {
  | #Just(unpacked) => unpacked
  }

let handleActions = Projection.handleActions // create alias to avoid shadowing of same named modules

module Make = (Projection: ReventlessSpec.Projection.Mapping): (
  T with type sourceEvent := Projection.sourceEvent and type targetState := Projection.targetState
) => {
  //module Source = Projection.Source
  //module Target = Projection.Target

  let testId = ref(TestFixtures.id)
  let meta = ref(TestFixtures.meta)

  let describe = Jest.describe
  let describeWithId = (description, id, fn) => {
    testId := id
    Jest.describe(description, fn)
  }
  let test = Jest.testPromise

  type store = Js.Dict.t<array<Projection.targetState>>

  let getSubId = state => Projection.subIdConfig->Belt.Option.map(({getSubId}) => state->getSubId)
  let hasSubId = (subId, state) => state->getSubId->Belt.Option.getExn == subId
  let states = (store, id) => store->Js.Dict.get(id)->Belt.Option.getWithDefault([])
  let setStates = (store, id, states) => store->Js.Dict.set(id, states)
  let updateState = (store, id, subId, newState) =>
    store->states(id)->Array.map(state => hasSubId(subId, state) ? newState : state)
  let addState = (store, id, state) => {
    let (updatedStates, newStates) = switch state->getSubId {
    | Some(subId) =>
      store->states(id)->Belt.Array.some(state => hasSubId(subId, state))
        ? (store->updateState(id, subId, state), [])
        : (store->states(id), [state])
    | None => (store->states(id), [state])
    }
    store->Js.Dict.set(id, Array.concat(updatedStates, newStates))
  }
  let deleteStates = (store, id) => store->Js.Dict.set(id, [])
  let deleteSubState = (store, id, subId, getSubId) =>
    store->Js.Dict.set(
      id,
      store
      ->Js.Dict.get(id)
      ->Belt.Option.map(states => states->Array.filter(state => state->getSubId != subId))
      ->Belt.Option.getWithDefault([]),
    )

  open Belt.Result
  //open QueryDb
  let load = (store, id) => store->states(id)->Ok->Js.Promise.resolve
  let save = (store, id, state, saveMode: QueryDb.saveMode, _ttl) =>
    switch (store->states(id), saveMode) {
    | (_, Any)
    | ([], Init)
    | ([_], Overwrite) =>
      store->setStates(id, [state])
      Ok()->Js.Promise.resolve
    | _ => Error(ReventlessSpec.QueryDb.StaleState)->Js.Promise.resolve
    }
  let saveBatch = (store, batch) => {
    batch->Belt.Array.forEach(((id, state, _ttl)) => store->addState(id, state))
    Ok()->Js.Promise.resolve
  }
  let delete = (store, id, subId) =>
    switch (subId, Projection.subIdConfig) {
    | (None, _) =>
      store->deleteStates(id)
      Ok()->Js.Promise.resolve
    | (Some((_, subId)), Some({ReventlessSpec.ReadModel_Spec.getSubId: getSubId})) =>
      store->deleteSubState(id, subId, getSubId)
      Ok()->Js.Promise.resolve
    | _ => Ok()->Js.Promise.resolve
    }
  let deleteBatch = (store, ids) => {
    ids->Belt.Array.forEach(((id, subId)) =>
      switch (subId, Projection.subIdConfig) {
      | (None, _) => store->deleteStates(id)
      | (Some((_, subId)), Some({ReventlessSpec.ReadModel_Spec.getSubId: getSubId})) =>
        store->deleteSubState(id, subId, getSubId)
      | _ => ()
      }
    )
    Ok()->Js.Promise.resolve
  }

  let handleActions = (actions, operations) =>
    actions->handleActions(operations, Projection.subIdConfig)

  let update = async (store, id, meta, event) => {
    /* NOTE: unused
    let logStore = text =>
      Js.log4(
        text,
        event->Projection.sourceEvent_encode,
        "\nstore:",
        Js.Dict.map(
          (states) => states->Belt.Array.toArray->Array.map(Projection.targetState_encode),
          store,
        ),
      )
 */

    await [{id, meta, event}->Projection.map]->handleActions({
      load: load(store, ...),
      save: save(store, ...),
      saveBatch: saveBatch(store, ...),
      count: async (_, _, _) => Ok(0),
      delete: delete(store, ...),
      deleteBatch: deleteBatch(store, ...),
    })
    store
  }

  let givenEvents = events =>
    events->Array.reduce(Js.Dict.empty()->Js.Promise.resolve, async (store, event) =>
      await (await store)->update(testId.contents, meta.contents, event)
    )
  let givenEventsWithTime = events =>
    events->Array.reduce(Js.Dict.empty()->Js.Promise.resolve, async (store, (time, event)) =>
      await (await store)->update(testId.contents, {...meta.contents, time}, event)
    )

  open Jest.Expect
  let whenEvent = (store, event) =>
    expect(async () => await (await store)->update(testId.contents, meta.contents, event))
  let whenEventWithTime = (store, time, event) =>
    expect(async () =>
      await (await store)->update(testId.contents, {...meta.contents, time}, event)
    )

  let thenStates = async (p, expectedStates) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Js.Dict.keys->Array.length,
      store->Js.Dict.keys->Belt.Array.get(0),
      store->Js.Dict.values->Belt.Array.get(0)->Belt.Option.getWithDefault([]),
    ))->toEqual((1, Some(testId.contents), expectedStates))
  }
  let thenStatesWithId = async (p, id, expectedStates) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Js.Dict.keys->Array.length,
      store->Js.Dict.keys->Belt.Array.get(0),
      store->Js.Dict.values->Belt.Array.get(0)->Belt.Option.getWithDefault([]),
    ))->toEqual((1, Some(id), expectedStates))
  }

  let thenAllStates = async (p, expectedStore: store) => {
    let store = await (p->unpackPlainPartial)()
    expect(store)->toEqual(expectedStore)
  }
  let thenState = async (p, expectedState) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Js.Dict.keys->Array.length,
      store->Js.Dict.keys->Belt.Array.get(0),
      store->Js.Dict.values->Belt.Array.get(0)->Belt.Option.getWithDefault([])->Array.length,
      store->Js.Dict.values->Array.getUnsafe(0)->Belt.Array.get(0),
    ))->toEqual((1, Some(testId.contents), 1, Some(expectedState)))
  }
  let thenStateWithId = async (p, id, expectedState) => {
    let store = await (p->unpackPlainPartial)()
    expect((
      store->Js.Dict.keys->Array.length,
      store->Js.Dict.keys->Belt.Array.get(0),
      store->Js.Dict.values->Belt.Array.get(0)->Belt.Option.getWithDefault([])->Array.length,
      store->Js.Dict.values->Array.getUnsafe(0)->Belt.Array.get(0),
    ))->toEqual((1, Some(id), 1, Some(expectedState)))
  }
  let thenNoState = async p => {
    let store = await (p->unpackPlainPartial)()
    expect(
      store->Js.Dict.values->Array.reduce(0, (acc, states) => acc + states->Array.length),
    )->toEqual(0)
  }
  let thenThrow = async p => {p->toThrow}

  let thenFail = async p =>
    switch await (p->unpackPlainPartial)() {
    | _ => Jest.fail("Expected Failure")
    | exception _ => Jest.pass
    }
}
