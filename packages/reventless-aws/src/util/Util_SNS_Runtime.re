let publish = (topic: PulumiAws.SNS.Topic.t, message) =>
  AwsSdk.SNS.publish(~topicArn=topic##arn->Pulumi.Output.get, ~message);