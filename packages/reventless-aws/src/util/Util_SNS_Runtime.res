type runtimeTopic = {
  id: string,
  name: string,
  arn: string,
}

let toRuntimeTopic = (topic: PulumiAws.SNS.Topic.t) => {
  id: topic.id->Pulumi.Output.get,
  name: topic.name->Pulumi.Output.get,
  arn: topic.arn->Pulumi.Output.get,
}

let publish = (topic, message) => AwsSdk.SNS.publish(~topicArn=topic.arn, message)

let publishFifo = (topic, ~messageGroupId, ~message) =>
  AwsSdk.SNS.publish(~topicArn=topic.arn, ~messageGroupId, message)
