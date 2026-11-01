// The event tap's lines besides events: each command's outcome, once, and each
// row a projection changed, its values redacted; a rejected command is also kept
// in the problem ring.

open JestGlobals

module Outcome = ReventlessCore.CommandTopic_Helpers
module ViewChange = ReventlessCore.ViewChange

let sleep = (ms: int): promise<unit> =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), ms)
  })

let until = async (~ms=2000, cond: unit => bool): bool => {
  let waited = ref(0)
  while !cond() && waited.contents < ms {
    await sleep(5)
    waited := waited.contents + 5
  }
  cond()
}

type client = {socket: NodeNet.socket, mutable received: string}

let connect = (port: int): promise<client> =>
  Promise.make((resolve, _) => {
    let c = ref(None)
    let socket = NodeNet.connect(port, "127.0.0.1", () =>
      c.contents->Option.forEach(client => resolve(client))
    )
    socket->NodeNet.setEncoding("utf8")
    socket->NodeNet.onSocketError(_ => ())
    let client = {socket, received: ""}
    socket->NodeNet.onSocketData(chunk => client.received = client.received ++ chunk)
    c := Some(client)
  })

/** The lines of a kind, as objects, without their time. */
let linesOf = (c: client, ~kind: string): array<dict<JSON.t>> =>
  c.received
  ->String.split("\n")
  ->Array.filterMap(l =>
    switch l->JSON.parseOrThrow->JSON.Decode.object {
    | Some(d) if d->Dict.get("kind") == Some(JSON.String(kind)) =>
      d->Dict.delete("ts")
      Some(d)
    | _ => None
    | exception _ => None
    }
  )

@schema
type row = {
  name: string,
  token: @s.matches(Reventless.Sensitive.string) string,
}

let connectTap = async () => {
  LocalEventTap.resetForTests()
  LocalLogFeed.resetForTests()
  LocalTapLines.resetForTests()
  LocalLogFeed.install(~env=Dict.make())
  LocalTapLines.install()
  let port = await Promise.make((resolve, _) =>
    LocalEventTap.start(~env=Dict.make(), ~onBound=resolve, ())
  )
  let tap = await connect(port)
  let _ = await until(() => LocalEventTap.hasReaders())
  tap
}

let disconnect = async (tap: client) => {
  NodeNet.destroySocket(tap.socket)
  LocalTapLines.resetForTests()
  await LocalEventTap.stopForTests()
  LocalLogFeed.resetForTests()
}

describe("LocalTapLines", () => {
  test("an accepted and a rejected command each appear once on the tap", async () => {
    let tap = await connectTap()

    Outcome.reportAccepted(
      ~component="Order",
      ~correlationId="flow-1",
      "m-1",
      {entityId: "o-1", eventCount: 2},
    )
    Outcome.reportRejected(
      ~component="Order",
      ~cause=DomainRejection,
      ~correlationId="flow-1",
      "m-2",
      {errorCode: "AlreadyExists", errorDetail: `{"name":"Widget"}`},
    )
    let _ = await until(() => tap->linesOf(~kind="commandOutcome")->Array.length >= 2)
    await sleep(20)

    expect(tap->linesOf(~kind="commandOutcome"))->toEqual([
      Dict.fromArray([
        ("kind", JSON.String("commandOutcome")),
        ("component", JSON.String("Order")),
        ("msgId", JSON.String("m-1")),
        ("correlationId", JSON.String("flow-1")),
        ("outcome", JSON.String("accepted")),
        ("entityId", JSON.String("o-1")),
        ("eventCount", JSON.Number(2.)),
      ]),
      Dict.fromArray([
        ("kind", JSON.String("commandOutcome")),
        ("component", JSON.String("Order")),
        ("msgId", JSON.String("m-2")),
        ("correlationId", JSON.String("flow-1")),
        ("outcome", JSON.String("rejected")),
        ("errorCode", JSON.String("AlreadyExists")),
        ("cause", JSON.String("DOMAIN")),
      ]),
    ])
    // Not an event line: no sentinel prefix.
    expect(tap.received->String.includes("@@RVLESS_EVT@@"))->toBe(false)

    // The rejection, and only it, is kept as a warning in the problem ring.
    let kept =
      LocalLogFeed.recentRecords(~filter={level: Warn})->Array.filter(
        r => r.message == "command rejected",
      )
    expect(kept->Array.map(r => (r.comp, r.annotations->Dict.get("msgId"))))->toEqual([
      (Some("CommandTopic(Order)"), Some("m-2")),
    ])
    expect(
      (kept->Array.getUnsafe(0)).detail->Option.map(j => j->JSON.stringify)->Option.getOr(""),
    )->toBe(`{"component":"Order","errorCode":"AlreadyExists","cause":"DOMAIN","errorDetail":{"name":"Widget"}}`)

    await disconnect(tap)
  })

  test("an infrastructure failure is kept as an error", async () => {
    let tap = await connectTap()
    Outcome.reportRejected(
      ~component="Order",
      ~cause=InfrastructureFailure,
      "m-3",
      {errorCode: "AppendFailed", errorDetail: "store down"},
    )
    let kept =
      LocalLogFeed.recentRecords(~filter={level: Error})->Array.filter(
        r => r.message == "command rejected",
      )
    expect(kept->Array.length)->toBe(1)
    await disconnect(tap)
  })

  test("a view change is sent with its values redacted", async () => {
    let tap = await connectTap()
    let onChange = ViewChange.reporter(
      ~comp="ReadModel(Accounts)",
      ~view="Accounts",
      ~stateToJson=r => r->Reventless.Util_Sury.toJson(rowSchema),
    )
    onChange({
      key: "a-1",
      kind: Changed,
      before: {name: "Ada", token: "old-secret"},
      after: {name: "Ada L.", token: "new-secret"},
      sources: [{msgId: "m-1", correlationId: "flow-1", entityId: "a-1", entityType: "Account"}],
    })
    let _ = await until(() => tap->linesOf(~kind="viewChange")->Array.length >= 1)

    let lines = tap->linesOf(~kind="viewChange")
    expect(lines->Array.length)->toBe(1)
    let line = lines->Array.getUnsafe(0)->JSON.Encode.object->JSON.stringify
    expect(line->String.includes("secret"))->toBe(false)
    expect(line->String.includes(Reventless.LogRedaction.placeholder))->toBe(true)
    expect(line->String.includes(`"name":"Ada L."`))->toBe(true)
    expect(
      line->String.startsWith(`{"kind":"viewChange","view":"Accounts","key":"a-1","change":"changed","fields":["name","token"],"sources":[{"msgId":"m-1","correlationId":"flow-1","entityId":"a-1","entityType":"Account"}],"correlationId":"flow-1","before":`),
    )->toBe(true)

    await disconnect(tap)
  })
})
