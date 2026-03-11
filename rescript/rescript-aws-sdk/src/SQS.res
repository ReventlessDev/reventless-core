/*** @aws-sdk/client-sqs
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/sqs/
*/
type client

type options = {
  region?: string,
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-sqs") @new
  external client: (~options: options, unit) => client = "SQSClient"
}

let clientInstance = ref(None)

let client = () =>
  switch clientInstance.contents {
  | None =>
    let client = Raw.client(
      ~options={
        maxAttempts: 5,
        requestHandler: NodeHttpHandler.make({
          connectionTimeout: 1000,
          requestTimeout: 5000,
        }),
      },
      (),
    )
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

type messageAttribute = {
  @as("Type") type_: string,
  @as("Value") value: string,
}

module SendMessageCommand = {
  type t

  type input = {
    @as("MessageBody") messageBody: string,
    @as("QueueUrl") queueUrl: string,
    @as("MessageAttributes") messageAttributes?: dict<messageAttribute>,
    @as("DelaySeconds") delaySeconds?: int, // 0 - 900
    @as("MessageDeduplicationId") messageDeduplicationId?: string,
    @as("MessageGroupId") messageGroupId?: string,
  }

  type output = {
    @as("MessageId") messageId: option<string>,
    @as("MD5OfMessageBody") md5OfMessageBody: option<string>,
    @as("MD5OfMessageAttributes") md5OfMessageAttributes: option<string>,
    @as("SequenceNumber") sequenceNumber: option<string>,
  }

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "SendMessageCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module BatchResultErrorEntry = {
  type t = {
    @as("Id") id: string,
    @as("SenderFault") senderFault: bool,
    @as("Code") code: string,
    @as("Message") message: option<string>,
  }
}

module SendMessageBatchCommand = {
  type t

  type sendMessageBatchEntry = {
    @as("Id") id: string,
    @as("MessageBody") messageBody: string,
    @as("MessageAttributes") messageAttributes?: dict<messageAttribute>,
    @as("DelaySeconds") delaySeconds?: int, // 0 - 900
    @as("MessageDeduplicationId") messageDeduplicationId?: string,
    @as("MessageGroupId") messageGroupId?: string,
  }

  type input = {
    @as("Entries") entries: array<sendMessageBatchEntry>,
    @as("QueueUrl") queueUrl: string,
  }

  type sendMessageBatchResultEntry = {
    @as("Id") id: string,
    @as("MessageId") messageId: option<string>,
    @as("MD5OfMessageBody") md5OfMessageBody: option<string>,
    @as("MD5OfMessageAttributes") md5OfMessageAttributes: option<string>,
    @as("SequenceNumber") sequenceNumber: option<string>,
  }

  type output = {
    @as("Successful") successful?: array<sendMessageBatchResultEntry>,
    @as("Failed") failed?: array<BatchResultErrorEntry.t>,
  }

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "SendMessageBatchCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }
  let send: t => promise<output> = command => Raw.send(client(), command)
}

module DeleteMessageCommand = {
  type t

  type input = {
    @as("QueueUrl") queueUrl: string,
    @as("ReceiptHandle") receiptHandle: string,
  }

  type output = {.}

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "DeleteMessageCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }
  let send: t => promise<output> = command => Raw.send(client(), command)
}

module DeleteMessageBatchCommand = {
  type t

  type deleteMessageBatchEntry = {
    @as("Id") id: string,
    @as("ReceiptHandle") receiptHandle: string,
  }

  type input = {
    @as("QueueUrl") queueUrl: string,
    @as("Entries") entries: array<deleteMessageBatchEntry>,
  }

  type deleteMessageBatchResultEntry = {@as("Id") id: string}

  type output = {
    @as("Successful") successful?: array<deleteMessageBatchResultEntry>,
    @as("Failed") failed?: array<BatchResultErrorEntry.t>,
  }

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "DeleteMessageBatchCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module AddPermissionCommand = {
  type t

  type input = {
    @as("AWSAccountIds") awsAccountIds: array<string>,
    @as("Actions") actions: array<string>,
    @as("Label") label: string,
    @as("QueueUrl") queueUrl: string,
  }

  type output = {.}

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "AddPermissionCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module GetQueueAttributesCommand = {
  type t

  type input = {
    @as("AttributeNames") attributeNames: array<string>,
    @as("QueueUrl") queueUrl: string,
  }

  type policy

  @val @scope("JSON")
  external unsafeParsePolicy: policy => IAM.Policy.t = "parse"

  type attributes = {@as("Policy") policy: policy}

  type output = {@as("Attributes") attributes: attributes}

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "GetQueueAttributesCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module SetQueueAttributesCommand = {
  type t

  type attributes = {@as("Policy") policy?: string}

  type input = {@as("Attributes") attributes: attributes, @as("QueueUrl") queueUrl: string}

  type output = {.}

  @new @module("@aws-sdk/client-sqs")
  external make: input => t = "SetQueueAttributesCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}
