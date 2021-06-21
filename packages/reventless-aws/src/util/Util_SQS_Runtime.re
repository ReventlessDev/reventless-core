let sendMessage = (queue: PulumiAws.SQS.Queue.t, messageBody) =>
  AwsSdk.SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    (),
  );

let sendFifoMessage =
    (
      queue: PulumiAws.SQS.Queue.t,
      ~messageBody,
      ~messageGroupId,
      ~messageDeduplicationId,
    ) =>
  AwsSdk.SQS.sendMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~messageBody,
    ~messageGroupId,
    ~messageDeduplicationId,
    (),
  );

let deleteMessage = (queue: PulumiAws.SQS.Queue.t, receiptHandle) =>
  AwsSdk.SQS.deleteMessage(
    ~queueId=queue##id->Pulumi.Output.get,
    ~receiptHandle,
  );
