open JestGlobals

// Guards the null a table without a sort key resolves to.
//
// Pulumi resolves an absent `rangeKey` to `null`, and ReScript's `option` reads
// None as undefined — so the null travelled into `resourceInfo` unconverted and
// the plugin-structure export threw `Expected string | undefined, received null`
// out of sury's encode-side validation, failing the deploy after it had already
// applied part of the stack.

let resolve = (output: Pulumi.Output.t<'a>): promise<'a> =>
  Promise.make((resolve, _) => {
    let _ = output->Pulumi.Output.apply(value => resolve(value))
  })

let table = (~rangeKey): PulumiAws.DynamoDb.Table.t => {
  arn: "arn:aws:dynamodb:eu-west-1:123456789012:table/UiFragments-abc123"->Pulumi.Output.make,
  name: "UiFragments-abc123"->Pulumi.Output.make,
  id: "UiFragments-abc123"->Pulumi.Output.make,
  hashKey: "id"->Pulumi.Output.make,
  rangeKey: rangeKey->Pulumi.Output.make,
  streamEnabled: None->Pulumi.Output.make,
  streamArn: ""->Pulumi.Output.make,
  streamLabel: ""->Pulumi.Output.make,
  ttl: {PulumiAws.DynamoDb.Table.attributeName: ""}->Pulumi.Output.make,
  pointInTimeRecovery: {PulumiAws.DynamoDb.Table.enabled: true}->Pulumi.Output.make,
}

describe("Util_DynamoDb.toResourceInfo", () => {
  test("reads a table without a sort key as None", async () => {
    let resourceInfo = await table(~rangeKey=Nullable.null)->Util_DynamoDb.toResourceInfo->resolve
    expect(resourceInfo)->toEqual(
      ReventlessInfra.Adapter.StorageKeys({partitionKey: "id", sortKey: None}),
    )
  })

  test("carries a sort key when the table has one", async () => {
    let resourceInfo =
      await table(~rangeKey=Nullable.make("seq"))->Util_DynamoDb.toResourceInfo->resolve
    expect(resourceInfo)->toEqual(
      ReventlessInfra.Adapter.StorageKeys({partitionKey: "id", sortKey: Some("seq")}),
    )
  })
})
