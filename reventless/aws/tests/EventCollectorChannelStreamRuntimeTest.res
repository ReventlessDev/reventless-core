// B3.0: the ReadModel/StateViewSlice record decoder must accept BOTH DynamoDB
// stream records (DynamoDB backend) and SQS records (Postgres backend — bodies
// injected by the PgChangeFeedRelay via the projection feed queue), in one batch.

open JestGlobals

let mkEvent = (records): PulumiAws.Lambda.CallbackFunction.event => Obj.magic({"Records": records})

let sqsRecord = body =>
  {
    "eventSource": "aws:sqs",
    "eventSourceARN": "arn:aws:sqs:eu-west-1:1:AllReadModelsFeed",
    "body": body,
  }

let run = event => {
  let seen: array<JSON.t> = []
  let handler: ReventlessCore.EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.runForEach(json => Effect.succeed(seen->Array.push(json)->ignore))
    ->Effect.map(_ => ())
  EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(handler, event, ())
  ->Effect.runPromise
  ->Promise.thenResolve(_ => seen)
}

describe("handleStreamEvent (ReadModel/SVS record decoder)", () => {
  test("parses SQS feed-queue records into their JSON bodies", async () => {
    let seen = await run(
      mkEvent([
        sqsRecord(`{"id":"agg-1","meta":{"service":"Product"},"event":{"type":"Added","data":{}}}`),
        sqsRecord(`{"id":"agg-2","meta":{"service":"Product"},"event":{"type":"Added","data":{}}}`),
      ]),
    )
    expect(seen->Array.length)->toBe(2)
    let id0 =
      seen
      ->Array.getUnsafe(0)
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("id"))
      ->Option.flatMap(JSON.Decode.string)
    expect(id0)->toEqual(Some("agg-1"))
  })

  test("skips malformed SQS bodies and unknown sources without failing the batch", async () => {
    let seen = await run(
      mkEvent([
        sqsRecord("not-json"),
        {"eventSource": "aws:kinesis", "eventSourceARN": "arn:x", "body": "{}"},
        sqsRecord(`{"ok":true}`),
      ]),
    )
    expect(seen->Array.length)->toBe(1)
  })
})
