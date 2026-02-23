/** @pulumi/aws/kinesis/Stream
  see: https://www.pulumi.com/registry/packages/aws/api-docs/kinesis/stream
*/
type t = {arn: Pulumi.Output.t<string>, name: Pulumi.Output.t<string>}
type stream = t

type args = {
  arn?: Pulumi.Input.t<string>,
  encryptionType?: Pulumi.Input.t<string>,
  kmsKeyId?: Pulumi.Input.t<string>,
  name?: Pulumi.Input.t<string>,
  retentionPeriod?: Pulumi.Input.t<int>,
  shardCount?: Pulumi.Input.t<int>,
  shardLevelMetrics?: Pulumi.Input.t<array<string>>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

type info = {
  data: string,
  kinesisSchemaVersion: string,
  partitionKey: string,
  sequenceNumber: string,
}

type record = {
  awsRegion: string,
  eventID: string,
  eventName: string,
  eventSource: string,
  eventSourceARN: string,
  eventVersion: string,
  invokeIdentityArn: string,
  kinesis: info,
}

type event = {@as("Records") records: array<record>}

type handler = Lambda.eventHandlerNoResult<event>

type subscriptionArgs = {
  startingPosition: Pulumi.Input.t<string>, //TODO enums
  batchSize?: Pulumi.Input.t<int>,
  startingPositionTimestamp?: Pulumi.Input.t<string>,
}

module EventSubscription = {
  type t = {
    name: string,
    stream: stream,
    handler: handler,
    args: subscriptionArgs,
    opts?: Pulumi.CustomResourceOptions.t,
  }
}

@module("@pulumi/aws") @scope("kinesis") @new
external make: (
  ~name: string,
  ~args: args=?,
  ~opts: Pulumi.CustomResourceOptions.t=?
) => stream = "Stream"

@send
external onEvent: (
  stream,
  ~name: string,
  ~handler: Lambda.eventHandlerNoResult<event>,
  ~args: subscriptionArgs=?,
  ~opts: Pulumi.CustomResourceOptions.t=?
) => EventSubscription.t = "onEvent"
