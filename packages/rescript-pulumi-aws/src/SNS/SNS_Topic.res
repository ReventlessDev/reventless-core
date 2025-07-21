/** @pulumi/aws/sns/topic
  see: https://www.pulumi.com/registry/packages/aws/api-docs/sns/topic
*/
type t = {
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
}

type args = {
  applicationFailureFeedbackRoleArn?: Pulumi.Input.t<string>,
  applicationSuccessFeedbackRoleArn?: Pulumi.Input.t<string>,
  applicationSuccessFeedbackSampleRate?: Pulumi.Input.t<float>,
  contentBasedDeduplication?: Pulumi.Input.t<bool>,
  deliveryPolicy?: Pulumi.Input.t<string>,
  displayName?: Pulumi.Input.t<string>,
  fifoTopic?: Pulumi.Input.t<bool>,
  httpFailureFeedbackRoleArn?: Pulumi.Input.t<string>,
  httpSuccessFeedbackRoleArn?: Pulumi.Input.t<string>,
  httpSuccessFeedbackSampleRate?: Pulumi.Input.t<float>,
  kmsMasterKeyId?: Pulumi.Input.t<string>,
  lambdaFailureFeedbackRoleArn?: Pulumi.Input.t<string>,
  lambdaSuccessFeedbackRoleArn?: Pulumi.Input.t<string>,
  lambdaSuccessFeedbackSampleRate?: Pulumi.Input.t<float>,
  name?: Pulumi.Input.t<string>,
  namePrefix?: Pulumi.Input.t<string>,
  policy?: Pulumi.Input.t<string>,
  sqsFailureFeedbackRoleArn?: Pulumi.Input.t<string>,
  sqsSuccessFeedbackRoleArn?: Pulumi.Input.t<string>,
  sqsSuccessFeedbackSampleRate?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("sns") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Topic"

type message = {
  @as("Message") message: string,
  @as("SignatureVersion") signatureVersion: option<string>,
  @as("Timestamp") timestamp: option<string>,
  @as("Signature") signature: option<string>,
  @as("SigningCertUrl") signingCertUrl: option<string>,
  @as("MessageId") messageId: option<string>,
  @as("Type") type_: option<string>,
  @as("UnsubscribeUrl") unsubscribeUrl: option<string>,
  @as("TopicArn") topicArn: option<string>,
  @as("Subject") subject: option<string>,
}

type record = {
  @as("EventVersion") eventVersion: string,
  @as("EventSubscriptionArn") eventSubscriptionArn: string,
  @as("EventSource") eventSource: string,
  @as("Sns") sns: message,
}

type event = {@as("Records") records: array<record>}

type eventSubscription

type eventSubscriptionArgs

@send
external onTopicEvent: (
  t,
  ~name: string,
  ~handler: Lambda.eventHandlerNoResult<'event>,
  ~args: args=?,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => eventSubscription = "onEvent"
