open JestGlobals

// Guards the CommandTopic queue policy. EventBridge Scheduler sends as the
// scheduler role, which holds sqs:SendMessage itself, so the queue admits no
// service but its consuming Lambda. A widened policy is invisible at deploy time.

let queueArn = "arn:aws:sqs:eu-west-1:123456789012:CatalogAggrCmdTopic-5150050"
let lambdaArn = "arn:aws:lambda:eu-west-1:123456789012:function:AllAggregates-1a2b3c4"

let policy =
  CommandTopicChannel_Helpers.createQueuePolicyDocument(
    ~name="CatalogAggrCmdTopic",
    ~queueArn,
    ~lambdaArn,
  )->JSON.parseOrThrow

let field = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))

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

describe("CommandTopic queue policy — services", () => {
  testSync("admits only the consuming Lambda", () => {
    let sids =
      policy
      ->field("Statement")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(s => s->field("Sid")->Option.flatMap(JSON.Decode.string))
    expect(sids)->toEqual(["AllowLambdaToAccessQueue"])
  })
})

describe("CommandTopic queue policy — Lambda grant", () => {
  testSync("stays pinned to the consuming function ARN", () => {
    expect(condition("AllowLambdaToAccessQueue", "ArnEquals", "AWS:SourceArn"))->toEqual(
      Some(lambdaArn),
    )
  })
})
