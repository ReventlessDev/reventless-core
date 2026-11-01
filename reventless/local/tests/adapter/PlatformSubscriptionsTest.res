// The platform API's subscriptions over the WebSocket: checked for the admin
// group like its queries, with the identity built from the connection; and the
// two feeds delivered as subscriptions, filtered.

@@warning("-44")

open JestGlobals

module Logger = ReventlessCore.Logger

type outcome = {values: array<JSON.t>, error: Nullable.t<string>}

@module("./GraphQLWsFixtures.mjs")
external collect: (string, string, dict<string>, int, int, unit => unit) => promise<outcome> =
  "collect"

let sleep = (ms: int): promise<unit> =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), ms)
  })

// A port of its own, away from the platform's defaults.
let port = 47_000 + Float.toInt(Math.random() *. 2000.)
let url = `ws://127.0.0.1:${port->Int.toString}/graphql`

let asAdmin = Dict.fromArray([("X-User", "admin")])
let asUser = Dict.make()

let field = (json: JSON.t, key: string): option<string> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(key))
  ->Option.flatMap(JSON.Decode.string)

describe("the platform API's subscriptions", () => {
  beforeAllAsync(async () => {
    LocalLogFeed.resetForTests()
    LocalLogFeed.install(~env=Dict.make())
    LocalEventTap.resetForTests()
    PlatformGraphQL_Server.reset()
    LocalPlatformObserve.registerGraphQL(PlatformGraphQL_Server.asInterface)
    // One of the kind the platform registered before: a plain topic field.
    PlatformGraphQL_Server.registerSubscriptions(
      ~sdlFields=["  onTestChange: String"],
      ~resolvers=Dict.fromArray([
        ("onTestChange", LocalGraphQL_SubscriptionResolvers.makeFieldResolver("onTestChange")),
      ]),
    )
    PlatformGraphQL_Server.start(~port, ~contextFactory=Auth_GraphqlContext.buildAuthContext, ())
    await sleep(100)
  })
  afterAll(() => {
    PlatformGraphQL_Server.stop()
    PlatformGraphQL_Server.reset()
    LocalLogFeed.resetForTests()
    LocalEventTap.resetForTests()
  })

  test("are refused to a caller without the admin group", async () => {
    let refused = async query => {
      let o = await collect(url, query, asUser, 1, 2000, () => ())
      o.values->Array.length == 0 && o.error->Nullable.toOption->Option.isSome
    }
    expect(await refused("subscription { Platform_LogAppended }"))->toBe(true)
    expect(await refused("subscription { Platform_EventAppended }"))->toBe(true)
    expect(await refused("subscription { onTestChange }"))->toBe(true)
  })

  test("deliver the log feed to an admin, filtered, the recent records first", async () => {
    Logger.emit(~level=Info, ~comp="Projection", ~plugin="Ordering", "quiet")
    Logger.emit(~level=Warn, ~comp="Projection", ~plugin="Ordering", "loud")
    Logger.emit(~level=Error, ~comp="Projection", ~plugin="Catalog", "elsewhere")
    let o = await collect(
      url,
      `subscription { Platform_LogAppended(filter: {plugins: ["Ordering"], level: WARN}) }`,
      asAdmin,
      2,
      3000,
      () => {
        let _ = setTimeout(
          () => {
            Logger.emit(~level=Info, ~comp="Projection", ~plugin="Ordering", "quiet again")
            Logger.emit(~level=Error, ~comp="Projection", ~plugin="Ordering", "live")
          },
          100,
        )
      },
    )
    expect(o.error->Nullable.toOption)->toEqual(None)
    expect(o.values->Array.map(v => v->field("message")))->toEqual([Some("loud"), Some("live")])
  })

  test("deliver the event tap to an admin, filtered", async () => {
    let ticker = ref(None)
    let o = await collect(
      url,
      `subscription { Platform_EventAppended(filter: {eventTypes: ["Placed"]}) }`,
      asAdmin,
      2,
      3000,
      () =>
        ticker :=
          Some(
            setInterval(
              () => {
                LocalEventTap.publish({
                  line: `@@RVLESS_EVT@@ {"event":"domainEvent","name":"shipped"}`,
                  facets: {eventType: "Shipped"},
                })
                LocalEventTap.publish({
                  line: `@@RVLESS_EVT@@ {"event":"domainEvent","name":"placed"}`,
                  facets: {eventType: "Placed"},
                })
              },
              20,
            ),
          ),
    )
    ticker.contents->Option.forEach(clearInterval)
    expect(o.error->Nullable.toOption)->toEqual(None)
    expect(o.values->Array.map(v => v->field("name")))->toEqual([Some("placed"), Some("placed")])
  })
})
