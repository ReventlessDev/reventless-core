// A Lambda's stream handler fetches the keys an event's sealed fields name before
// the component decodes it, and asks for nothing when an event names none.

open JestGlobals

let asked: ref<array<array<string>>> = ref([])
let provider: Reventless.Pii.provider = {
  ...Reventless.Pii.plain,
  name: "counting",
  prefetch: async keyIds => {
    asked := asked.contents->Array.concat([keyIds])
    Ok()
  },
}

let sealed =
  Dict.fromArray([
    (
      "event",
      Dict.fromArray([
        ("TAG", JSON.Encode.string("MemberNamed")),
        ("name", Reventless.Pii.wrap("enc:v1:k-7:fake:AAAA")),
      ])->JSON.Encode.object,
    ),
  ])->JSON.Encode.object

describe("StreamRoutedEntryPoint_Ops.withPreparedKeys", () => {
  beforeEach(() => {
    asked := []
    Reventless.Pii.Provider.install(provider)
  })
  afterEach(() => Reventless.Pii.Provider.install(Reventless.Pii.plain))

  testPromise("prefetches before the handler sees the event, and only what it names", async () => {
    let seen = ref([])
    let handler: ReventlessCore.EventCollector.jsonEventsHandler = stream =>
      stream->Stream.runForEach(
        json =>
          Effect.sync(
            () => seen := seen.contents->Array.concat([(json, asked.contents->Array.length)]),
          ),
      )
    let wrapped = StreamRoutedEntryPoint_Ops.withPreparedKeys(handler)
    let _ = await wrapped(
      Stream.fromIterable([sealed, JSON.Encode.string("plain")]),
    )->Effect.runPromise
    expect(asked.contents)->toEqual([["k-7"]])
    // The sealed event arrived after its key was asked for.
    expect(seen.contents->Array.map(((_, n)) => n))->toEqual([1, 1])
  })
})
