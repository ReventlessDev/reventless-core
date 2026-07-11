// Focused seam test for the promoted, transport-neutral GraphQL server runtime
// (`ReventlessGraphqlServer.GraphQL_ServerInstance` + `GraphQL_SubscriptionBridge`).
//
// The promotion introduced ONE behavioral seam: the subscription bridge takes
// its PubSub instance as a *parameter* instead of constructing a module
// singleton. This test drives the promoted modules directly with an
// **explicitly injected** in-process PubSub (never the local singleton) to
// prove the parameterized-PubSub seam is behavior-preserving:
//
//   1. registerAll builds the subscription SDL on a fresh GraphQL_ServerInstance,
//      strips @aws_subscribe, and injects `scalar AWSJSON`.
//   2. A resolver from makeFieldResolver, subscribed on the injected PubSub,
//      receives a payload published via Bridge.publish on that same PubSub.

@@warning("-44")

open JestGlobals

module Bridge = ReventlessGraphqlServer.GraphQL_SubscriptionBridge
module Server = ReventlessGraphqlServer.GraphQL_ServerInstance

// AsyncIterable.next() binding — yoga's PubSub returns {value, done}.
type asyncIterResult = {value: JSON.t, done: bool}
@send external iterNext: 'a => promise<asyncIterResult> = "next"

@val external setTimeout: (unit => unit, int) => int = "setTimeout"

// The subscription resolver object shape produced by makeFieldResolver.
// `subscribe` returns yoga's Repeater-based AsyncIterable (kept opaque).
type iterable
type subResolver = {
  subscribe: (JSON.t, JSON.t, JSON.t) => iterable,
  resolve: JSON.t => JSON.t,
}

let startConsumer = (iter: 'iter, timeoutMs: int): promise<Null.t<JSON.t>> => {
  let timeoutP = Promise.make((resolve, _) => {
    let _: int = setTimeout(() => resolve(Null.null), timeoutMs)
  })
  let consumeP = async () =>
    try {
      let result = await iter->iterNext
      result.done ? Null.null : result.value->Null.make
    } catch {
    | _ => Null.null
    }
  Promise.race([timeoutP, consumeP()])
}

let yieldTick = (): promise<unit> =>
  Promise.make((resolve, _) => {
    let _: int = setTimeout(() => resolve(), 10)
  })

describe("GraphQL_SubscriptionBridge — injected PubSub seam", () => {
  testSync("registerAll builds subscription SDL, strips @aws_subscribe, injects AWSJSON", () => {
    let pubSub = GraphqlYoga.createPubSub()
    let server = Server.make(~label="SeamTest")

    let sdlField =
      "onCatalogProduct_stateChanged: CatalogProduct\n    @aws_subscribe(mutations: [\"addProduct\"])"

    Bridge.registerAll(
      ~server,
      ~sdlFields=[sdlField],
      ~sourceAEntries=[],
      ~sourceBEntries=[{fieldName: "onCatalogProduct_stateChanged", topic: "onCatalogProduct_stateChanged"}],
      ~pubSub,
    )

    let sdl = server.buildSdl()
    expect(sdl->String.includes("type Subscription"))->toBe(true)
    expect(sdl->String.includes("onCatalogProduct_stateChanged"))->toBe(true)
    // @aws_subscribe is AppSync-only and must be stripped for yoga.
    expect(sdl->String.includes("@aws_subscribe"))->toBe(false)
    // AWSJSON scalar injected so yoga accepts AppSync-derived event log types.
    expect(sdl->String.includes("scalar AWSJSON"))->toBe(true)
  })

  testPromise("makeFieldResolver + publish deliver over the injected PubSub", async () => {
    let pubSub = GraphqlYoga.createPubSub()
    let topic = "onCatalogProduct_stateChanged"

    let resolver: subResolver = Obj.magic(Bridge.makeFieldResolver(~pubSub, topic))
    let iter = resolver.subscribe(JSON.Encode.null, JSON.Encode.null, JSON.Encode.null)
    let consumerPromise = startConsumer(iter, 1000)
    await yieldTick()

    let payload =
      JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.string("prod-1"))]))
    Bridge.publish(~pubSub, topic, payload)

    let received = await consumerPromise
    switch received->Null.toOption {
    | Some(msg) => expect(msg)->toEqual(payload)
    | None => expect("injected-pubsub: timed out")->toBe("received")
    }
  })

  testPromise("a separate injected PubSub does NOT receive another's publish", async () => {
    // Proves isolation: publishing on PubSub A never reaches a subscriber on B.
    let pubSubA = GraphqlYoga.createPubSub()
    let pubSubB = GraphqlYoga.createPubSub()
    let topic = "onCatalogProduct_stateChanged"

    let resolverB: subResolver = Obj.magic(Bridge.makeFieldResolver(~pubSub=pubSubB, topic))
    let iterB = resolverB.subscribe(JSON.Encode.null, JSON.Encode.null, JSON.Encode.null)
    let consumerPromise = startConsumer(iterB, 300)
    await yieldTick()

    Bridge.publish(
      ~pubSub=pubSubA,
      topic,
      JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.string("prod-1"))])),
    )

    let received = await consumerPromise
    expect(received->Null.toOption)->toEqual(None)
  })
})
