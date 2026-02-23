/*** @aws-sdk/client-sqs
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/sqs/
*/
type client

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
// Example URL: https://sqs.eu-west-1.amazonaws.com/xxxxxx/MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Url = arn =>
  switch arn->String.split(":") {
  | [_, _, service, region, account, queueName] =>
    `https://${service}.${region}.amazonaws.com/${account}/${queueName}`
  | _ => ""
  }

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

let sendMessage = async (
  ~queueId,
  ~messageBody,
  ~messageGroupId=?,
  ~messageDeduplicationId=?,
  ~delay=?,
) =>
  (
    await SendMessageCommand.send(
      SendMessageCommand.make({
        queueUrl: queueId,
        messageBody,
        messageGroupId: ?(messageGroupId->Option.map(id => id->String.replaceRegExp(/ /g, ""))),
        ?messageDeduplicationId,
        delaySeconds: ?(
          delay->Option.map(delay =>
            if delay > 900 {
              Console.log2(
                "WARNING: [" ++
                (__MODULE__ ++
                (":" ++
                (__LINE__->Int.toString ++
                ("] SQS.sendMessage was called with a delay set to higher than 900 seconds, " ++ "which is the maximum amount supported by AWS.")))),
                "DelaySeconds was automatically set to 900 to prevent failure.",
              )
              900
            } else {
              delay
            }
          )
        ),
      }),
    )
  )->ignore

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

let validateDelay = Option.map(_, delay =>
  if delay > 900 {
    Console.log2(
      "WARNING: [" ++
      (__MODULE__ ++
      (":" ++
      (__LINE__->Int.toString ++
      ("] SQS.sendMessage was called with a delay set to higher than 900 seconds, " ++ "which is the maximum amount supported by AWS.")))),
      "DelaySeconds was automatically set to 900 to prevent failure.",
    )
    900
  } else {
    delay
  }
)

let makeBatchEntry = (
  ~messageBody,
  ~messageId,
  ~delay=?,
): SendMessageBatchCommand.sendMessageBatchEntry => {
  messageBody,
  id: messageId,
  delaySeconds: ?(delay->validateDelay),
}

let makeBatchEntryFifo = (
  ~groupId,
  ~messageBody,
  ~messageId,
  ~delay=?,
): SendMessageBatchCommand.sendMessageBatchEntry => {
  messageBody,
  id: messageId,
  delaySeconds: ?(delay->validateDelay),
  messageGroupId: groupId->String.replaceRegExp(/ /g, ""),
}

let maxBatchMessages = 10 // defined by SQS
let maxBatchBytes = 262144 // defined by SQS

//FIXME: 1:1 like handleDeleteBatchPromises, only difference is in types of parameters
let handleSendBatchPromises: (
  array<promise<SendMessageBatchCommand.output>>,
  array<SendMessageBatchCommand.sendMessageBatchEntry>,
  string,
) => promise<array<array<string>>> = (promises, entries, name) => {
  promises
  ->Array.mapWithIndex(async (promise, idx) => {
    let batchNr = (idx + 1)->Int.toString
    switch await promise {
    | response =>
      response.failed
      ->Option.getOr([])
      ->Array.map(failure => {
        let id = failure.id
        let failureCode = failure.code
        let failureMessage = failure.message->Option.getOr("unknown message")
        Console.log(
          `Error: SQS.${name} batch ${batchNr} entry failed: ${id}, ${failureCode}, ${failureMessage}`,
        )
        id
      })
    | exception exn =>
      let error =
        exn
        ->JsExn.fromException
        ->Option.flatMap(exn => exn->JsExn.message)
        ->Option.getOr("unknown error")
      Console.log(`Error: SQS.${name} batch ${batchNr} failed: ${error}`)
      let start = idx * maxBatchMessages
      let end = start + maxBatchMessages
      entries
      ->Array.slice(~start, ~end)
      ->Array.map(entry => entry.id)
    }
  })
  ->Promise.all
}

let handleBatchResult = failedIds =>
  switch failedIds->Array.flat {
  | [] => Ok()
  | failedIds => Error(failedIds)
  }

let sendMessagesParallel = async (
  ~queueId,
  entries: array<SendMessageBatchCommand.sendMessageBatchEntry>,
) => {
  let totalMessageCount = entries->Array.length
  let batchNr = ref(0)
  let start = ref(0)
  let batchPromises = []

  let sliceBatch = start => {
    let end = ref(start)
    let batchBytes = ref(0)
    let messageBytes = () => (entries->Array.getUnsafe(end.contents)).messageBody->String.length
    while (
      end.contents < totalMessageCount &&
      end.contents < start + maxBatchMessages &&
      batchBytes.contents + messageBytes() <= maxBatchBytes
    ) {
      batchBytes := batchBytes.contents + messageBytes()
      end := end.contents + 1
    }
    if end.contents == start {
      Console.log("SQS.sendMessagesParallel: no message sent !!")
    }

    (end.contents, entries->Array.slice(~start, ~end=end.contents))
  }

  while start.contents < totalMessageCount {
    let (nextStart, batchEntries) = sliceBatch(start.contents)
    batchNr := batchNr.contents + 1
    start := nextStart

    let messages = batchEntries->Array.map(({messageBody}) => messageBody)
    let messageCountStr = messages->Array.length->Int.toString
    let messageBytes = messages->Array.map(message => message->String.length)
    let batchBytes = messageBytes->Array.reduce(0, (acc, a) => acc + a)
    let messageBytesStr = messageBytes->Array.map(size => size->Int.toString)->Array.joinUnsafe(",")
    Console.log(
      `SQS.sendMessagesParallel: batchNr:${batchNr.contents->Int.toString} messageCount:${messageCountStr} batchBytes: ${batchBytes->Int.toString}, messageBytes: ${messageBytesStr}`,
    )

    let _ = batchPromises->Array.push(
      SendMessageBatchCommand.make({
        queueUrl: queueId,
        entries: batchEntries,
      })->SendMessageBatchCommand.send,
    )
  }

  (await batchPromises->handleSendBatchPromises(entries, "sendMessagesParallel"))->handleBatchResult
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

//FIXME: 1:1 like handleSendBatchPromises, only difference is in types of parameters
let handleDeleteBatchPromises: (
  array<promise<DeleteMessageBatchCommand.output>>,
  array<DeleteMessageBatchCommand.deleteMessageBatchEntry>,
  string,
) => promise<array<array<string>>> = (promises, entries, name) => {
  promises
  ->Array.mapWithIndex(async (promise, idx) => {
    let batchNr = (idx + 1)->Int.toString
    switch await promise {
    | output =>
      output.failed
      ->Option.getOr([])
      ->Array.map(failure => {
        let id = failure.id
        let failureCode = failure.code
        let failureMessage = failure.message->Option.getOr("unknown message")
        Console.log(
          `Error: SQS.${name} batch ${batchNr} entry failed: ${id}, ${failureCode}, ${failureMessage}`,
        )
        id
      })
    | exception exn =>
      let error =
        exn
        ->JsExn.fromException
        ->Option.flatMap(exn => exn->JsExn.message)
        ->Option.getOr("unknown error")
      Console.log(`Error: SQS.${name} batch ${batchNr} failed: ${error}`)
      let start = idx * maxBatchMessages
      let end = start + maxBatchMessages
      entries
      ->Array.slice(~start, ~end)
      ->Array.map(entry => entry.id)
    }
  })
  ->Promise.all
}

let deleteMessagesParallel = async (
  ~queueId,
  entries: array<DeleteMessageBatchCommand.deleteMessageBatchEntry>,
) => {
  let arraySize =
    (entries->Array.length->Int.toFloat /. maxBatchMessages->Int.toFloat)->Math.Int.ceil

  (
    await Array.fromInitializer(~length=arraySize, batchNr => {
      let start = batchNr * maxBatchMessages
      let end = start + maxBatchMessages
      DeleteMessageBatchCommand.send(
        DeleteMessageBatchCommand.make({
          queueUrl: queueId,
          entries: entries->Array.slice(~start, ~end),
        }),
      )
    })->handleDeleteBatchPromises(entries, "deleteMessagesParallel")
  )->handleBatchResult
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

let getQueuePolicy = async queueArn => {
  let response = await GetQueueAttributesCommand.send(
    GetQueueAttributesCommand.make({
      attributeNames: ["Policy"],
      queueUrl: queueArn->arn2Url,
    }),
  )

  response.attributes.policy->GetQueueAttributesCommand.unsafeParsePolicy
}

let setQueuePolicy = async (queueArn, policy: IAM.Policy.t) =>
  switch policy->JSON.stringifyAny {
  | Some(newPolicy) =>
    let _setQueueAttributesResponse = await SetQueueAttributesCommand.send(
      SetQueueAttributesCommand.make({
        attributes: {
          policy: newPolicy,
        },
        queueUrl: queueArn->arn2Url,
      }),
    )
  | None => Console.log("Couldn't stringify policy")
  }
