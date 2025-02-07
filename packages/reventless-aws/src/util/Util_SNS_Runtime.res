type runtimeTopic = {
  id: string,
  name: string,
  arn: string,
}

let publish = (topic, message) => AwsSdk.SNS.publish(~topicArn=topic.arn, message)

let publishFifo = (topic, ~messageGroupId, ~message) =>
  AwsSdk.SNS.publish(~topicArn=topic.arn, ~messageGroupId, message)
