open JestGlobals

// Guards that a stream resource describes its own stream.
//
// `toStreamResource` used to leave `resourceInfo` at its `NoInfo` default even
// though it was built FROM a stream ARN. The event-topic resources a DynamoDB
// stream publisher exports are these, so every reader that asks an event topic
// for its stream ARN — `Upload_Claim_S3` does, to grant its Lambda
// `dynamodb:GetRecords` — took the arm that has no ARN to give and failed the
// deploy. The failure only surfaced once a plugin's first StateChangeSlice
// declared a `@storageRef` field, which is what registers the claimer at all.

let resolve = (output: Pulumi.Output.t<'a>): promise<'a> =>
  Promise.make((resolve, _) => {
    let _ = output->Pulumi.Output.apply(value => resolve(value))
  })

let streamArn = "arn:aws:dynamodb:eu-west-1:123456789012:table/CatalogDcbEventLog-abc123/stream/2026-01-01T00:00:00.000"

let tableResource = ReventlessInfra.Adapter.make(
  ~name="CatalogDcbEventLog-abc123"->Pulumi.Output.make,
  ~id="CatalogDcbEventLog-abc123"->Pulumi.Output.make,
  ~urn="arn:aws:dynamodb:eu-west-1:123456789012:table/CatalogDcbEventLog-abc123"->Pulumi.Output.make,
  ~service=AWS.DynamoDbStream.service->Pulumi.Output.make,
  ~resourceInfo=ReventlessInfra.Adapter.StreamSource({sourceUrn: streamArn})->Pulumi.Output.make,
)

describe("Util_DynamoDbStream.toStreamResource", () => {
  test("carries the source stream in resourceInfo", async () => {
    let stream = tableResource->Util_DynamoDbStream.toStreamResource
    let resourceInfo = await stream.resourceInfo->resolve
    expect(resourceInfo)->toEqual(ReventlessInfra.Adapter.StreamSource({sourceUrn: streamArn}))
  })

  test("answers its own stream ARN", async () => {
    let arn =
      await tableResource
      ->Util_DynamoDbStream.toStreamResource
      ->Util_DynamoDbStream.streamArnFromDynamoDbTableResource
      ->resolve
    expect(arn)->toBe(streamArn)
  })
})
