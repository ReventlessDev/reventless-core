// An automation's work item that carries personal data is stored as an event is:
// its marked fields sealed, its row keyed by a fingerprint of the key the mapping
// chose, that key sealed inside the item for `process` and `resolve`, and an item
// whose subject was erased completed without processing.

open JestGlobals

module Source = {
  module Id = Reventless.Id.String
  let name = "GreetDcbEventLog"
  @schema
  type event =
    | MemberJoined({memberId: @s.matches(Reventless.DcbTag.string) string, email: string})
    | MemberGreeted({memberId: @s.matches(Reventless.DcbTag.string) string, email: string})
}

module Spec = {
  let name = "GreetMember"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {
    memberId: string,
    email: @s.matches(Reventless.Pii.mark(~subject="memberId", S.string)) string,
  }

  @schema
  type command = SendGreeting({memberId: @s.matches(Reventless.DcbTag.string) string, key: string})

  let maxRetries = 3
  let targetName = "SendGreeting"
  let schedule = None
}

// Keyed by the address, as a translation keyed by contact would be.
module Mapping = Reventless.AutomationSlice.Mapping.Make(
  Source,
  Spec,
  {
    let collect = (event: Source.event, ~sourceId as _, _ctx) =>
      switch event {
      | MemberJoined({memberId, email}) => [
          (`${memberId}:${email}`, ({memberId, email}: Spec.todoItem)),
        ]
      | MemberGreeted(_) => []
      }
    let resolve = (event: Source.event) =>
      switch event {
      | MemberGreeted({memberId, email}) => Some(`${memberId}:${email}`)
      | MemberJoined(_) => None
      }
    let reschedule = _ => []
  },
)

let processed: ref<array<(string, string)>> = ref([])

module Automation: Reventless.AutomationSlice.Automation with module Spec := Spec = {
  let process = (key, item: Spec.todoItem, ~now as _) => {
    processed := processed.contents->Array.concat([(key, item.email)])
    Some((item.memberId, Spec.SendGreeting({memberId: item.memberId, key})))
  }
  let onExhausted = (_id, _item: Spec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = Reventless.AutomationSlice.Mappings.Make(Spec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(Mapping)]
}

module Callback = ReventlessCore.AutomationSlice_Callback.Make(Spec, Automation)

let context: Reventless.AutomationSlice.context = {
  environment: "test",
  platformName: "local",
  pluginName: "TestPlugin",
  sliceName: "GreetMember",
}

let envelope = (event: Source.event) =>
  JSON.Encode.object(
    Dict.fromArray([
      ("id", JSON.Encode.string("m-1")),
      (
        "meta",
        ReventlessCore.Message.generateMeta(~service=Source.name)->Reventless.Util_Sury.toJson(
          Reventless.Message.metaSchema,
        ),
      ),
      ("event", event->Reventless.Util_Sury.toJson(Source.eventSchema)),
    ]),
  )

let toBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "utf8")->NodeCrypto.bufferToString("base64")
let fromBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "base64")->NodeCrypto.bufferToString("utf8")

let erased = ref(false)
let provider: Reventless.Pii.provider = {
  name: "fake",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, json) => Ok(
    Reventless.Pii.wrap(`enc:v1:${subject}:fake:${json->JSON.stringify->toBase64}`),
  ),
  prefetch: async _ => Ok(),
  openNow: (~field, json) =>
    switch json->Reventless.Pii.unwrap->Option.flatMap(Reventless.Pii.parseStored) {
    | Some(Cipher(_)) if erased.contents => Ok(Reventless.Pii.wrap(Reventless.Pii.erasedMarker))
    | Some(Cipher({bytes})) => Ok(bytes->fromBase64->JSON.parseOrThrow)
    | _ => Error(Reventless.Pii.UnknownForm({field: field}))
    },
  release: async (~subject as _, ~ref as _) => Ok(),
}

let keyed: Reventless.Capabilities.t = {
  ...Reventless.Capabilities.none,
  secrets: Reventless.Secrets.fixed(
    ~token="t",
    ~hash=s => s,
    ~fingerprint=(~purpose, input) =>
      `fp(${purpose})#${input->toBase64->String.length->Int.toString}`,
  ),
}

let joined = Source.MemberJoined({memberId: "m-1", email: "ada@example.org"})
let greeted = Source.MemberGreeted({memberId: "m-1", email: "ada@example.org"})
let rows = () => Callback.todoItems->Dict.toArray
let published: ref<array<Reventless.Message.commandJson>> = ref([])
let publish: ReventlessInfra.CommandTopic.publishJsons = async msgs => {
  published := published.contents->Array.concat(msgs)
}

describe("an automation's work item with personal data", () => {
  beforeEach(() => {
    Callback.todoItems->Dict.keysToArray->Array.forEach(k => Callback.todoItems->Dict.delete(k))
    processed := []
    published := []
    erased := false
    Reventless.Pii.Provider.install(provider)
  })
  afterEach(() => Reventless.Pii.Provider.install(Reventless.Pii.plain))

  testPromise("is stored sealed, under a key that holds no address", async () => {
    await Callback.phase1([envelope(joined)], context, ~capabilities=keyed)
    expect(rows()->JSON.stringifyAny->Option.getOr("")->String.includes("ada@example.org"))->toBe(
      false,
    )
    expect(
      rows()->Array.every(((id, _)) => id->String.startsWith("fp(automationWorkItem:GreetMember)")),
    )->toBe(true)
    expect(rows()->Array.length)->toBe(1)
  })

  testPromise("is processed with the key and the value it was collected with", async () => {
    await Callback.phase1([envelope(joined)], context, ~capabilities=keyed)
    await Callback.phase2(publish)
    expect(processed.contents)->toEqual([("m-1:ada@example.org", "ada@example.org")])
    expect(published.contents->Array.length)->toBe(1)
  })

  testPromise("is resolved by the key the mapping chose", async () => {
    await Callback.phase1([envelope(joined)], context, ~capabilities=keyed)
    await Callback.phase1([envelope(greeted)], context, ~capabilities=keyed)
    expect(rows()->Array.map(((_, row)) => row.status))->toEqual([
      ReventlessCore.AutomationSlice_Callback.Completed,
    ])
  })

  testPromise("is completed without processing once its subject is erased", async () => {
    await Callback.phase1([envelope(joined)], context, ~capabilities=keyed)
    erased := true
    await Callback.phase2(publish)
    expect(processed.contents)->toEqual([])
    expect(rows()->Array.map(((_, row)) => row.status))->toEqual([
      ReventlessCore.AutomationSlice_Callback.Completed,
    ])
  })
})
