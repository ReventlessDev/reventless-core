// Integration test: Bus events + QueryDb writes → yoga PubSub → subscription delivery.
//
// Phase 6 verification (Sources A and B).
// Source C (mutation-triggered) is not covered: in-memory mutation resolvers would
// need to cross-publish to the subscription PubSub, which is future work.
//
// The test subscribes to the yoga PubSub topic directly (rather than going through
// a real WebSocket connection) — this validates the bus→PubSub bridge, which is the
// integration Reventless owns. yoga's own graphql-ws transport is framework territory.

@@warning("-44")

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

// AsyncIterable.next() binding. yoga's PubSub returns `{value: JSON.t, done: bool}`.
type asyncIterResult = {value: JSON.t, done: bool}
@send external iterNext: 'a => promise<asyncIterResult> = "next"

@val external setTimeout: (unit => unit, int) => int = "setTimeout"

// Start consuming an AsyncIterable eagerly so its listener registers before
// the publisher fires. Returns a Promise resolving to the first message
// (or null on timeout / iterator close / error). yoga's Repeater-based
// AsyncIterable registers its push callback lazily on first next() — so this
// must be called (and then yieldTick awaited) before publishing.
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

// Yield one macrotask so the consumer above has registered its push listener.
let yieldTick = (): promise<unit> =>
  Promise.make((resolve, _) => {
    let _: int = setTimeout(() => resolve(), 10)
  })

let testMeta: ReventlessCore.Message.meta = {
  service: "test",
  time: "2025-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

describe("GraphQL_SubscriptionResolvers_InMemory", () => {
  beforeEach(() => {
    GraphQL_SubscriptionResolvers_InMemory.reset()
  })

  describe("Source B — state-change bridge", () => {
    testPromise("Bus.publishStateChange → yoga PubSub subscriber receives state", async () => {
      module TestBus = InMemory_Bus.Make()

      // Wire the bridge before subscribing, so the bus callback publishes to the PubSub.
      GraphQL_SubscriptionResolvers_InMemory.bridgeSourceB(
        ~subscribeToStateChanges=TestBus.subscribeToStateChanges,
        ~readModelName="Product",
        ~returnTypeName="CatalogProduct",
      )

      // Start the consumer BEFORE publishing — yoga's PubSub drops messages
      // on topics whose AsyncIterable listener isn't registered yet.
      let ps = GraphQL_SubscriptionResolvers_InMemory.getPubSub()
      let iter = ps->GraphqlYoga.pubSubSubscribe("onCatalogProduct_stateChanged")
      let consumerPromise = startConsumer(iter, 1000)
      await yieldTick() // ensure listener is registered before publish

      // Trigger a state change on the bus.
      let state = JSON.Encode.object(
        Dict.fromArray([
          ("id", JSON.Encode.string("prod-1")),
          ("name", JSON.Encode.string("Widget")),
        ]),
      )
      TestBus.publishStateChange(~name="Product", ~state)

      let received = await consumerPromise
      switch received->Null.toOption {
      | Some(msg) => expect(msg)->toEqual(state)
      | None => expect("onCatalogProduct_stateChanged: timed out")->toBe("received")
      }
    })

    testPromise("state change for unregistered ReadModel → no publish", async () => {
      module TestBus = InMemory_Bus.Make()

      GraphQL_SubscriptionResolvers_InMemory.bridgeSourceB(
        ~subscribeToStateChanges=TestBus.subscribeToStateChanges,
        ~readModelName="Product",
        ~returnTypeName="CatalogProduct",
      )

      let ps = GraphQL_SubscriptionResolvers_InMemory.getPubSub()
      let iter = ps->GraphqlYoga.pubSubSubscribe("onCatalogProduct_stateChanged")
      let consumerPromise = startConsumer(iter, 300)
      await yieldTick()

      // Publish for a DIFFERENT ReadModel — should NOT reach our topic.
      TestBus.publishStateChange(
        ~name="Category",
        ~state=JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.string("cat-1"))])),
      )

      let received = await consumerPromise
      expect(received->Null.toOption)->toEqual(None)
    })
  })

  describe("Source A — event-stream bridge", () => {
    testPromise("Bus.publishEvent → yoga PubSub subscriber receives event", async () => {
      module TestBus = InMemory_Bus.Make()

      GraphQL_SubscriptionResolvers_InMemory.bridgeSourceA(
        ~subscribeToEvents=TestBus.subscribeToEvents,
        ~displayName="Catalog",
        ~busTopicName="catalog-events",
      )

      let ps = GraphQL_SubscriptionResolvers_InMemory.getPubSub()
      let iter = ps->GraphqlYoga.pubSubSubscribe("onCatalogEventLog_eventAppended")
      let consumerPromise = startConsumer(iter, 1000)
      await yieldTick()

      let event = JSON.Encode.object(
        Dict.fromArray([
          ("eventType", JSON.Encode.string("ProductAdded")),
          ("id", JSON.Encode.string("prod-1")),
          ("name", JSON.Encode.string("Widget")),
        ]),
      )
      await TestBus.publishEvent("catalog-events", "svc", testMeta, event)

      let received = await consumerPromise
      switch received->Null.toOption {
      | Some(msg) => expect(msg)->toEqual(event)
      | None => expect("onCatalogEventLog_eventAppended: timed out")->toBe("received")
      }
    })
  })
})
