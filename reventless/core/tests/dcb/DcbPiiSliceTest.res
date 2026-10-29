// A DCB slice seals a personal field once, stores and publishes that one form,
// opens it when it reads its history back, and refuses an append whose field comes
// out unsealed.

open JestGlobals

module MemberSpec = {
  let name = "TestMemberNames"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    | MemberNamed({
        memberId: @s.matches(Reventless.DcbTag.string) string,
        name: @s.matches(Reventless.Pii.marked(~subject="memberId", S.string))
        Reventless.Pii.t<string>,
      })

  @schema
  type consumedEvent =
    | MemberNamed({
        memberId: @s.matches(Reventless.DcbTag.string) string,
        name: @s.matches(Reventless.Pii.marked(~subject="memberId", S.string))
        Reventless.Pii.t<string>,
      })

  @schema
  type command = Name({memberId: @s.matches(Reventless.DcbTag.string) string, name: string})

  @schema
  type error = Never

  type state = option<Reventless.Pii.t<string>>
  let initialState = None
  let evolve = (_state, event) =>
    switch event {
    | MemberNamed({name}) => Some(name)
    }
  // Naming a member the same again is a no-op: only a history read back as the
  // value, opened, can tell.
  let decide = (state, command): result<array<event>, error> =>
    switch (state, command) {
    | (Some(Reventless.Pii.Value(held)), Name({name})) if held == name => Ok([])
    | (_, Name({memberId, name})) => Ok([MemberNamed({memberId, name: Value(name)})])
    }
}

module Decision = {
  type state = MemberSpec.state
  let initialState = MemberSpec.initialState
  let evolve = MemberSpec.evolve
  let decide = MemberSpec.decide
  let moduleUrl = MemberSpec.moduleUrl
}
module Handler = StateChangeSlice_Callback.Make(MemberSpec, Decision)

let mock = DcbFixtures.makeMockStorage()
module Ops = DcbEventLog_Operations.Make({
  let name = "TestDcbEventLog"
  let serviceName = "TestDcbEventLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
})
let log: DcbEventLog.operations = {
  read: Ops.read,
  append: Ops.append,
  readStream: Ops.readStream,
  appendStream: Ops.appendStream,
}

let toBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "utf8")->NodeCrypto.bufferToString("base64")
let fromBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "base64")->NodeCrypto.bufferToString("utf8")

let fakeProvider = (~seals=true): Reventless.Pii.provider => {
  name: "fake",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, json) =>
    seals
      ? Ok(Reventless.Pii.wrap(`enc:v1:${subject}:fake:${json->JSON.stringify->toBase64}`))
      : Ok(json),
  prefetch: async _ => Ok(),
  openNow: (~field, json) =>
    switch json->Reventless.Pii.unwrap->Option.flatMap(Reventless.Pii.parseStored) {
    | Some(Cipher({bytes})) => Ok(bytes->fromBase64->JSON.parseOrThrow)
    | _ => Error(Reventless.Pii.UnknownForm({field: field}))
    },
  release: async (~subject as _, ~ref as _) => Ok(),
}

let send = async (reference, command) =>
  await Handler.handleCommands(
    log,
    Stream.fromIterable([
      (
        {
          command: {
            id: Reventless.Id.String.makeFromString("cmd-" ++ reference),
            meta: DcbFixtures.testMeta,
            command,
          },
          reference,
        }: CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, MemberSpec.command>>
      ),
    ]),
  )->Effect.runPromise

let field = (json, name) => json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(name))

describe("a DCB slice with a personal-data provider", () => {
  beforeEach(() => {
    mock.reset()
    Handler.resetCache()
  })
  afterEach(() => Reventless.Pii.Provider.install(Reventless.Pii.plain))

  testPromise("stores and publishes one sealed form, and decides on the opened value", async () => {
    Reventless.Pii.Provider.install(fakeProvider())
    let _ = await send("r1", Name({memberId: "m-1", name: "Ada"}))
    let stored = (mock.getEvents()->Array.getUnsafe(0)).data->field("name")
    expect(stored->Option.flatMap(Reventless.Pii.unwrap)->Option.isSome)->toBe(true)
    let published =
      (mock.publishedEvents.contents->Array.getUnsafe(0)).json
      ->field("event")
      ->Option.flatMap(e => e->field("name"))
    expect(published)->toEqual(stored)
    // Read back cold: only an opened history makes the same name a no-op.
    Handler.resetCache()
    let _ = await send("r2", Name({memberId: "m-1", name: "Ada"}))
    expect(mock.getEvents()->Array.length)->toBe(1)
  })

  testPromise("refuses an append whose personal field comes out unsealed", async () => {
    Reventless.Pii.Provider.install(fakeProvider(~seals=false))
    let results = await send("r1", Name({memberId: "m-1", name: "Ada"}))
    expect(results->Array.every(Result.isError))->toBe(true)
    expect(mock.getEvents())->toEqual([])
    expect(mock.publishedEvents.contents)->toEqual([])
  })
})
