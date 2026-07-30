// LocalEvents_Server protocol tests — socket-free.
//
// A `connection` is just a capturing `send` callback + subscription dict, so
// the AppSync Events frame handling, wildcard matching, LocalBus bridge and
// the publish route are all driven without a WebSocket. The ws attach glue is
// the only part not covered here (framework territory + a real socket).

open JestGlobals

let _ = TestRunner.setup()

let sentFrames: ref<array<string>> = ref([])

let makeConn = () => {
  sentFrames := []
  LocalEvents_Server.addConnection(~send=f => sentFrames.contents->Array.push(f))
}

let parseFrame = (s: string): dict<JSON.t> =>
  s->JSON.parseOrThrow->JSON.Decode.object->Option.getOr(Dict.make())

let frameField = (s: string, field: string): option<string> =>
  parseFrame(s)->Dict.get(field)->Option.flatMap(JSON.Decode.string)

let descriptor = (~id: string): JSON.t =>
  Dict.fromArray([
    ("changeKind", JSON.Encode.string("Updated")),
    ("id", JSON.Encode.string(id)),
    ("sortKeyValue", JSON.Encode.string("2026-07-28T00:00:00Z")),
  ])->JSON.Encode.object

describe("LocalEvents_Server", () => {
  beforeEach(() => LocalEvents_Server.resetConnections())

  describe("channelMatches", () => {
    testSync("exact match", () => {
      expect(
        LocalEvents_Server.channelMatches(
          ~subscription="/default/Product/p-1",
          ~channel="/default/Product/p-1",
        ),
      )->toBe(true)
    })
    testSync("wildcard prefix matches any depth", () => {
      expect(
        LocalEvents_Server.channelMatches(
          ~subscription="/default/Product/*",
          ~channel="/default/Product/p-1",
        ),
      )->toBe(true)
      expect(
        LocalEvents_Server.channelMatches(
          ~subscription="/default/*",
          ~channel="/default/Product/p-1/deep",
        ),
      )->toBe(true)
    })
    testSync("wildcard does not match a sibling with the same stem", () => {
      expect(
        LocalEvents_Server.channelMatches(
          ~subscription="/default/Product/*",
          ~channel="/default/ProductArchive/p-1",
        ),
      )->toBe(false)
    })
    testSync("non-wildcard mismatch", () => {
      expect(
        LocalEvents_Server.channelMatches(
          ~subscription="/default/Product/p-1",
          ~channel="/default/Product/p-2",
        ),
      )->toBe(false)
    })
  })

  describe("subscribe protocol", () => {
    testSync("connection_init is answered with connection_ack", () => {
      let conn = makeConn()
      LocalEvents_Server.handleFrame(conn, `{"type":"connection_init"}`)
      expect(sentFrames.contents->Array.length)->toBe(1)
      expect(sentFrames.contents->Array.getUnsafe(0)->frameField("type"))->toEqual(
        Some("connection_ack"),
      )
    })

    testSync("subscribe → state change → data frame on the subscription id", () => {
      let conn = makeConn()
      LocalEvents_Server.handleFrame(
        conn,
        `{"type":"subscribe","id":"sub-1","channel":"/default/Product/*"}`,
      )
      expect(sentFrames.contents->Array.getUnsafe(0)->frameField("type"))->toEqual(
        Some("subscribe_success"),
      )
      LocalEvents_Server.broadcastStateChange(~name="Product", ~descriptor=descriptor(~id="p-1"))
      expect(sentFrames.contents->Array.length)->toBe(2)
      let data = sentFrames.contents->Array.getUnsafe(1)
      expect(data->frameField("type"))->toEqual(Some("data"))
      expect(data->frameField("id"))->toEqual(Some("sub-1"))
      // `event` is a stringified JSON payload — parse the string to verify.
      let event =
        data->frameField("event")->Option.getOr("")->JSON.parseOrThrow->JSON.Decode.object
      expect(
        event->Option.flatMap(o => o->Dict.get("id"))->Option.flatMap(JSON.Decode.string),
      )->toEqual(Some("p-1"))
    })

    testSync("channel segments are normalized like the AWS publisher", () => {
      let conn = makeConn()
      LocalEvents_Server.handleFrame(
        conn,
        `{"type":"subscribe","id":"s","channel":"/default/My-Model/order-1-2026"}`,
      )
      // Read-model name `My.Model` and entity key `order#1@2026` normalize to
      // the subscribed channel (`[^A-Za-z0-9-]` → `-`).
      LocalEvents_Server.broadcastStateChange(
        ~name="My.Model",
        ~descriptor=descriptor(~id="order#1@2026"),
      )
      expect(sentFrames.contents->Array.length)->toBe(2)
    })

    testSync("publishes on the plugin-qualified list field, not the store name", () => {
      // The channel root the client subscribes on is the read model's
      // `listFieldName` ("Catalog_Products"), not its store name ("Products").
      // The publish must translate through the same registry the AWS StateTopic
      // wiring uses — otherwise the descriptor lands on a channel no one listens
      // to and the socket stays Open while no view refreshes.
      let registry = ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
      registry->Dict.set(
        "Products",
        {
          ReventlessCore.Api_Naming.singleFieldName: "Catalog_Product",
          listFieldName: "Catalog_Products",
          returnTypeName: "Catalog_Product",
          pluralTypeName: "Catalog_Products",
          includeIdParam: false,
          connectionSpec: true,
        },
      )
      let conn = makeConn()
      LocalEvents_Server.handleFrame(
        conn,
        `{"type":"subscribe","id":"s","channel":"/default/Catalog-Products/*"}`,
      )
      LocalEvents_Server.broadcastStateChange(~name="Products", ~descriptor=descriptor(~id="SKU-1"))
      // subscribe_success + a data frame ⇒ the descriptor reached the client's channel
      expect(sentFrames.contents->Array.length)->toBe(2)
      expect(sentFrames.contents->Array.getUnsafe(1)->frameField("type"))->toEqual(Some("data"))
      registry->Dict.delete("Products")
    })

    testSync("unsubscribe stops delivery", () => {
      let conn = makeConn()
      LocalEvents_Server.handleFrame(
        conn,
        `{"type":"subscribe","id":"sub-1","channel":"/default/Product/*"}`,
      )
      LocalEvents_Server.handleFrame(conn, `{"type":"unsubscribe","id":"sub-1"}`)
      LocalEvents_Server.broadcastStateChange(~name="Product", ~descriptor=descriptor(~id="p-1"))
      // subscribe_success + unsubscribe_success, but no data frame
      expect(sentFrames.contents->Array.length)->toBe(2)
      expect(sentFrames.contents->Array.getUnsafe(1)->frameField("type"))->toEqual(
        Some("unsubscribe_success"),
      )
    })

    testSync("malformed and unknown frames are ignored", () => {
      let conn = makeConn()
      LocalEvents_Server.handleFrame(conn, `not json`)
      LocalEvents_Server.handleFrame(conn, `{"type":"mystery"}`)
      LocalEvents_Server.handleFrame(conn, `{"type":"subscribe","id":"only-id"}`)
      expect(sentFrames.contents->Array.length)->toBe(0)
    })
  })

  describe("handlePublish", () => {
    testSync("rejects non-client channels with 403", () => {
      let (status, _) = LocalEvents_Server.handlePublish(
        ~authorization=None,
        ~body=`{"channel":"/default/Product/p-1","events":["{}"]}`,
      )
      expect(status)->toBe(403)
    })

    testSync("rejects an unverifiable token with 401", () => {
      let (status, _) = LocalEvents_Server.handlePublish(
        ~authorization=Some("garbage-token"),
        ~body=`{"channel":"/client/x","events":["{}"]}`,
      )
      expect(status)->toBe(401)
    })

    testSync("rejects malformed bodies with 400", () => {
      let (s1, _) = LocalEvents_Server.handlePublish(~authorization=None, ~body=`nope`)
      let (s2, _) = LocalEvents_Server.handlePublish(
        ~authorization=None,
        ~body=`{"channel":"/client/x","events":[]}`,
      )
      expect(s1)->toBe(400)
      expect(s2)->toBe(400)
    })

    testSync("fans out to a wildcard subscriber and accounts per event", () => {
      let conn = makeConn()
      LocalEvents_Server.handleFrame(
        conn,
        `{"type":"subscribe","id":"sub-p","channel":"/client/shop/presence/*"}`,
      )
      let (status, response) = LocalEvents_Server.handlePublish(
        ~authorization=None,
        ~body=`{"channel":"/client/shop/presence/room-1","events":["{\\"userId\\":\\"u1\\"}","not json",42]}`,
      )
      expect(status)->toBe(200)
      let counts =
        response
        ->JSON.Decode.object
        ->Option.map(o => (
          o->Dict.get("successful")->Option.flatMap(JSON.Decode.array)->Option.getOr([])->Array.length,
          o->Dict.get("failed")->Option.flatMap(JSON.Decode.array)->Option.getOr([])->Array.length,
        ))
      expect(counts)->toEqual(Some((1, 2)))
      // subscribe_success + one data frame for the one valid event
      expect(sentFrames.contents->Array.length)->toBe(2)
      let data = sentFrames.contents->Array.getUnsafe(1)
      expect(data->frameField("id"))->toEqual(Some("sub-p"))
      expect(data->frameField("event"))->toEqual(Some(`{"userId":"u1"}`))
    })
  })
})
