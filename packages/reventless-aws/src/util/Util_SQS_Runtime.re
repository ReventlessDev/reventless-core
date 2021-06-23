let sendMessage = (queue: PulumiAws.SQS.Queue.t, messageBody) =>
  AwsSdk.SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    (),
  );

let sendFifoMessage =
    (queue: PulumiAws.SQS.Queue.t, ~messageBody, ~messageGroupId) =>
  AwsSdk.SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    ~messageGroupId,
    (),
  );

let deleteMessage = (queue: PulumiAws.SQS.Queue.t, receiptHandle) =>
  AwsSdk.SQS.deleteMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~receiptHandle,
  );
