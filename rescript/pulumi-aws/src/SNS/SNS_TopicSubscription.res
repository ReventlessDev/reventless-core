/** @pulumi/aws/sns/topicsubscription
  see: https://www.pulumi.com/registry/packages/aws/api-docs/sns/topicsubscription
*/
type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type protocol =
  | @as("sqs") SQS
  | @as("sms") SMS
  | @as("lambda") Lambda
  | @as("email") Email
  | @as("email-json") EmailJson
  | @as("http") Http
  | @as("https") Https
  | @as("application") Application

type args = {
  endpoint: Pulumi.Input.t<string>,
  topic: Pulumi.Input.t<string>,
  protocol: protocol,
  // Only valid for the sqs/http(s) protocols; AWS rejects it for email/sms.
  rawMessageDelivery?: Pulumi.Input.t<bool>,
}

@module("@pulumi/aws") @scope("sns") @new
external make: (~name: string, ~args: args=?, ~opts: option<Pulumi.CustomResourceOptions.t>) => t =
  "TopicSubscription"
