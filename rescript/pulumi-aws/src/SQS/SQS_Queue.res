/**@pulumi/aws/sqsqueue
  see: https://www.pulumi.com/registry/packages/aws/api-docs/sqs/queue
*/
type t = {
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
}

module RedrivePolicy = {
  type t = string

  @obj
  external redrivePolicy: (~deadLetterTargetArn: string, ~maxReceiveCount: int) => _ = ""

  let make: (~deadLetterTargetArn: string, ~maxReceiveCount: int) => t = (
    ~deadLetterTargetArn,
    ~maxReceiveCount,
  ) =>
    redrivePolicy(~deadLetterTargetArn, ~maxReceiveCount)
    ->JSON.stringifyAny
    ->Option.getOr("{}")
}

type deduplicationScope = | @as("queue") Queue | @as("messageGroup") MessageGroup
type fifoThroughputLimit = | @as("perQueue") PerQueue | @as("perMessageGroupId") PerMessageGroupId

type args = {
  contentBasedDeduplication?: Pulumi.Input.t<bool>,
  delaySeconds?: Pulumi.Input.t<int>,
  fifoQueue?: Pulumi.Input.t<bool>,
  kmsDataKeyReusePeriodSeconds?: Pulumi.Input.t<int>,
  kmsMasterKeyId?: Pulumi.Input.t<string>,
  maxMessageSize?: Pulumi.Input.t<int>,
  messageRetentionSeconds?: Pulumi.Input.t<int>,
  name?: Pulumi.Input.t<string>,
  namePrefix?: Pulumi.Input.t<string>,
  policy?: Pulumi.Input.t<string>,
  receiveWaitTimeSeconds?: Pulumi.Input.t<int>,
  redrivePolicy?: Pulumi.Input.t<RedrivePolicy.t>,
  tags?: Pulumi.Input.t<Aws.tags>,
  visibilityTimeoutSeconds?: Pulumi.Input.t<int>,
  deduplicationScope?: deduplicationScope,
  fifoThroughputLimit?: fifoThroughputLimit,
  sqsManagedSseEnabled?: Pulumi.Input.t<bool>,
}

@module("@pulumi/aws") @scope("sqs") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Queue"

@module("@pulumi/aws") @scope(("sqs", "Queue"))
external get: (
  ~name: string,
  ~id: Pulumi.Input.t<string>,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => t = "get"

type record = {
  messageId: string,
  receiptHandle: string,
  body: string,
  // attributes: sqsRecordAttributes,
  // messageAttributes: sqsMessageAttributes,
  md5OfBody: string,
  md5OfMessageAttributes?: string,
  eventSource: string,
  eventSourceARN: string,
  awsRegion: string,
}

external asRecord: Lambda.CallbackFunction.record => record = "%identity"

type event = {@as("Records") records: array<record>}

type eventSubscriptionArgs = {batchSize?: int}

type eventSubscription = {
  eventSourceMapping: EventSourceMapping.t,
  queue: t,
}

@send
external onEvent: (
  t,
  ~name: string,
  ~handler: Lambda.CallbackFunction.t,
  ~args: eventSubscriptionArgs=?,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => eventSubscription = "onEvent"

external toResource: t => Pulumi.Resource.t = "%identity"
