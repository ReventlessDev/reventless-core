// The table a deployed stash keeps its values in: one item per key, removed by
// DynamoDB some time after its expiry. Encrypted at rest with the table's key, as
// every table is. No point-in-time recovery: what it holds is a secret meant to
// be gone in minutes, and a backup would keep it for weeks.

type table = {name: Pulumi.Output.t<string>, arn: Pulumi.Output.t<string>}

let make = (~name: string="Stash", ~opts: Pulumi.ComponentResource.options): table => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let table = PulumiAws.DynamoDb.Table.make(
    ~name,
    ~args={
      attributes: [
        {PulumiAws.DynamoDb.Table.name: Stash_DynamoDb_Backend.keyAttribute, type_: "S"},
      ]->Pulumi.Input.make,
      hashKey: Stash_DynamoDb_Backend.keyAttribute->Pulumi.Input.make,
      billingMode: PAY_PER_REQUEST,
      ttl: (
        {
          attributeName: Stash_DynamoDb_Backend.expiryAttribute,
          enabled: true,
        }: PulumiAws.DynamoDb.Table.ttl
      )->Pulumi.Input.make,
      pointInTimeRecovery: (
        {enabled: false}: PulumiAws.DynamoDb.Table.pointInTimeRecovery
      )->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name=name ++ "Table",
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Other("Stash"),
        ~scope=Platform,
      ),
    },
    ~opts,
  )
  {name: table.name, arn: table.arn}
}
