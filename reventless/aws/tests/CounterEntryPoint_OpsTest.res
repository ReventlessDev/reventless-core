// Guards the typed cold-start core hoisted out of CounterEntryPoint.mjs:
//   - parseHandlerConfig — reads `publishChannelId`, the field the deploy side
//     (CounterHandler_DynamoDbStream.res) actually writes; the former shell
//     read `publishQueueUrl` and published CountFinished events to an
//     undefined queue URL.
//   - splitRecords — the references/counts stream routing: NewImage rows carry
//     increments (unparsable inc falls back to 1), NewAndOldImage on the
//     references stream is a duplicate to ignore, counts take the new image on
//     insert AND update, and foreign records are dropped.

open JestGlobals

let attrS = (s: string): AwsSdk.DynamoDb.Util.attributeValue => {string: s}
let attrN = (n: string): AwsSdk.DynamoDb.Util.attributeValue => {number: n}

let refsArn = "arn:stream-references"
let countsArn = "arn:stream-counts"

let mkRecord = (
  ~arn: string,
  ~source="aws:dynamodb",
  ~keysId: string,
  ~newImage: option<dict<AwsSdk.DynamoDb.Util.attributeValue>>=?,
  ~oldImage: option<dict<AwsSdk.DynamoDb.Util.attributeValue>>=?,
): PulumiAws.DynamoDb.Stream.record => {
  awsRegion: "eu-west-1",
  dynamodb: {
    keys: {id: attrS(keysId)},
    newImage: ?newImage,
    oldImage: ?oldImage,
  },
  eventID: "e1",
  eventName: INSERT,
  eventSource: source,
  eventSourceARN: arn,
  eventVersion: "1",
  userIdentity: "",
}

describe("CounterEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("reads publishChannelId (the field the deploy side writes)", () => {
    let config = CounterEntryPoint_Ops.parseHandlerConfig(
      `{"targetSpecModule":"@x/p/src/Aggregate/Product.res.mjs","countsTableName":"counts","publishChannelId":"https://sqs/q","referencesStreamArn":"${refsArn}","countsStreamArn":"${countsArn}"}`,
    )
    expect(config.publishChannelId)->toEqual(Some("https://sqs/q"))
    expect(config.countsTableName)->toEqual(Some("counts"))
    expect(config.referencesStreamArn)->toEqual(Some(refsArn))
  })
})

describe("CounterEntryPoint_Ops.splitRecords", () => {
  testSync("routes references and counts records by source ARN", () => {
    let records = [
      // references insert: {id, inc} view row → increment 2
      mkRecord(
        ~arn=refsArn,
        ~keysId="c1#ref-a",
        ~newImage=Dict.fromArray([("id", attrS("c1#ref-a")), ("inc", attrN("2"))]),
      ),
      // references insert without a parsable inc → fallback 1
      mkRecord(
        ~arn=refsArn,
        ~keysId="c1#ref-b",
        ~newImage=Dict.fromArray([("id", attrS("c1#ref-b"))]),
      ),
      // references update (NewAndOldImage) → duplicate, ignored
      mkRecord(
        ~arn=refsArn,
        ~keysId="c1#ref-a",
        ~newImage=Dict.fromArray([("id", attrS("c1#ref-a")), ("inc", attrN("1"))]),
        ~oldImage=Dict.fromArray([("id", attrS("c1#ref-a")), ("inc", attrN("1"))]),
      ),
      // counts insert AND update both take the new image
      mkRecord(
        ~arn=countsArn,
        ~keysId="c1",
        ~newImage=Dict.fromArray([("id", attrS("c1")), ("count", attrN("0"))]),
      ),
      mkRecord(
        ~arn=countsArn,
        ~keysId="c2",
        ~newImage=Dict.fromArray([("id", attrS("c2")), ("count", attrN("3"))]),
        ~oldImage=Dict.fromArray([("id", attrS("c2")), ("count", attrN("4"))]),
      ),
      // foreign stream / foreign source → dropped
      mkRecord(
        ~arn="arn:other",
        ~keysId="x",
        ~newImage=Dict.fromArray([("id", attrS("x"))]),
      ),
      mkRecord(
        ~arn=refsArn,
        ~source="aws:sqs",
        ~keysId="y",
        ~newImage=Dict.fromArray([("id", attrS("y"))]),
      ),
    ]

    let (references, counts) = CounterEntryPoint_Ops.splitRecords(
      ~referencesStreamArn=refsArn,
      ~countsStreamArn=countsArn,
      records,
    )

    expect(references)->toEqual([("c1#ref-a", 2), ("c1#ref-b", 1)])
    expect(counts->Array.length)->toBe(2)
    expect(
      counts
      ->Array.getUnsafe(1)
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("count"))
      ->Option.flatMap(JSON.Decode.float),
    )->toEqual(Some(3.))
  })
})
