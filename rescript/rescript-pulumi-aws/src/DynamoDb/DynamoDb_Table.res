/** @pulumi/aws/dynamodb/table
  see: https://www.pulumi.com/registry/packages/aws/api-docs/dynamodb/table
*/
type ttl = {attributeName: string, enabled?: bool}
type pointInTimeRecovery = {enabled: bool}

type t = {
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  hashKey: Pulumi.Output.t<string>,
  rangeKey: Pulumi.Output.t<option<string>>,
  streamEnabled: Pulumi.Output.t<option<bool>>,
  streamArn: Pulumi.Output.t<string>,
  streamLabel: Pulumi.Output.t<string>,
  ttl: Pulumi.Output.t<ttl>,
  pointInTimeRecovery: Pulumi.Output.t<pointInTimeRecovery>,
}
type table = t

type projectionType = KEYS_ONLY | ALL | INCLUDE

type globalSecondaryIndex = {
  hashKey: string,
  name: string,
  projectionType: projectionType,
  nonKeyAttributes?: array<string>,
  rangeKey?: string,
  readCapacity?: int,
  writeCapacity?: int,
}

type localSecondaryIndex = {
  name: string,
  nonKeyAttributes?: array<string>,
  projectionType: projectionType,
  rangeKey: string,
}

type attribute = {name: string, @as("type") type_: string}
type streamViewType = KEYS_ONLY | NEW_IMAGE | OLD_IMAGE | NEW_AND_OLD_IMAGES
type billingMode = PROVISIONED | PAY_PER_REQUEST

type args = {
  attributes: Pulumi.Input.t<array<attribute>>,
  hashKey: Pulumi.Input.t<string>,
  billingMode: billingMode,
  rangeKey?: Pulumi.Input.t<string>,
  name?: Pulumi.Input.t<string>,
  globalSecondaryIndexes?: Pulumi.Input.t<array<Pulumi.Input.t<globalSecondaryIndex>>>,
  localSecondaryIndexes?: Pulumi.Input.t<array<Pulumi.Input.t<localSecondaryIndex>>>,
  readCapacity?: Pulumi.Input.t<int>,
  writeCapacity?: Pulumi.Input.t<int>,
  tags?: Pulumi.Input.t<Aws.tags>,
  streamEnabled?: bool,
  streamViewType?: streamViewType,
  ttl?: Pulumi.Input.t<ttl>,
  pointInTimeRecovery?: Pulumi.Input.t<pointInTimeRecovery>,
  restoreSourceName?: Pulumi.Input.t<string>,
  restoreDateTime?: Pulumi.Input.t<string>,
  restoreToLatestTime?: Pulumi.Input.t<bool>,
}

@module("@pulumi/aws") @scope("dynamodb") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => table =
  "Table"
