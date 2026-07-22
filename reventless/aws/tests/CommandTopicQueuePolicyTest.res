open JestGlobals

// Guards the CommandTopic queue policy's service-principal scoping. The
// EventBridge grant cannot name a single rule ARN — ScheduledPublisher creates
// rules at runtime and EventBridge authorises SQS targets against the queue's
// resource policy — so the condition keys are the only bound on who may send
// into a command topic. A dropped condition is invisible at deploy time.

let queueArn = "arn:aws:sqs:eu-west-1:123456789012:CatalogAggrCmdTopic-5150050"
let lambdaArn = "arn:aws:lambda:eu-west-1:123456789012:function:AllAggregates-1a2b3c4"

let policy =
  CommandTopicChannel_Helpers.createQueuePolicyDocument(
    ~name="CatalogAggrCmdTopic",
    ~queueArn,
    ~lambdaArn,
  )->JSON.parseOrThrow

let field = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))

let statement = sid =>
  policy
  ->field("Statement")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.find(s => s->field("Sid")->Option.flatMap(JSON.Decode.string) == Some(sid))

let condition = (sid, operator, key) =>
  statement(sid)
  ->Option.flatMap(s => s->field("Condition"))
  ->Option.flatMap(c => c->field(operator))
  ->Option.flatMap(o => o->field(key))
  ->Option.flatMap(JSON.Decode.string)

describe("CommandTopic queue policy — EventBridge grant", () => {
  testSync("is scoped to this account", () => {
    expect(
      condition("AllowCloudWatchEventsToSendToQueue", "StringEquals", "aws:SourceAccount"),
    )->toEqual(Some("123456789012"))
  })

  testSync("is scoped to EventBridge rule ARNs in this account", () => {
    expect(condition("AllowCloudWatchEventsToSendToQueue", "ArnLike", "aws:SourceArn"))->toEqual(
      Some("arn:aws:events:*:123456789012:rule/*"),
    )
  })

  testSync("names the EventBridge service principal", () => {
    let principal =
      statement("AllowCloudWatchEventsToSendToQueue")
      ->Option.flatMap(s => s->field("Principal"))
      ->Option.flatMap(p => p->field("Service"))
      ->Option.flatMap(JSON.Decode.string)
    expect(principal)->toEqual(Some("events.amazonaws.com"))
  })
})

describe("CommandTopic queue policy — Lambda grant", () => {
  testSync("stays pinned to the consuming function ARN", () => {
    expect(condition("AllowLambdaToAccessQueue", "ArnEquals", "AWS:SourceArn"))->toEqual(
      Some(lambdaArn),
    )
  })
})
