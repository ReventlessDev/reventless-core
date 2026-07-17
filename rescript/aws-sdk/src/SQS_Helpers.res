// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
// Example URL: https://sqs.eu-west-1.amazonaws.com/xxxxxx/MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Url = arn =>
  switch arn->String.split(":") {
  | [_, _, service, region, account, queueName] =>
    `https://${service}.${region}.amazonaws.com/${account}/${queueName}`
  | _ => ""
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

let sendMessage = async (
  ~queueId,
  ~messageBody,
  ~messageGroupId=?,
  ~messageDeduplicationId=?,
  ~delay=?,
) =>
  (
    await SQS.SendMessageCommand.send(
      SQS.SendMessageCommand.make({
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

let makeBatchEntry = (
  ~messageBody,
  ~messageId,
  ~delay=?,
): SQS.SendMessageBatchCommand.sendMessageBatchEntry => {
  messageBody,
  id: messageId,
  delaySeconds: ?(delay->validateDelay),
}

let makeBatchEntryFifo = (
  ~groupId,
  ~messageBody,
  ~messageId,
  ~delay=?,
): SQS.SendMessageBatchCommand.sendMessageBatchEntry => {
  messageBody,
  id: messageId,
  delaySeconds: ?(delay->validateDelay),
  messageGroupId: groupId->String.replaceRegExp(/ /g, ""),
}

let maxBatchMessages = 10 // defined by SQS
let maxBatchBytes = 262144 // defined by SQS

//FIXME: 1:1 like handleDeleteBatchPromises, only difference is in types of parameters
let handleSendBatchPromises: (
  array<promise<SQS.SendMessageBatchCommand.output>>,
  array<SQS.SendMessageBatchCommand.sendMessageBatchEntry>,
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
  entries: array<SQS.SendMessageBatchCommand.sendMessageBatchEntry>,
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
      SQS.SendMessageBatchCommand.make({
        queueUrl: queueId,
        entries: batchEntries,
      })->SQS.SendMessageBatchCommand.send,
    )
  }

  (await batchPromises->handleSendBatchPromises(entries, "sendMessagesParallel"))->handleBatchResult
}

//FIXME: 1:1 like handleSendBatchPromises, only difference is in types of parameters
let handleDeleteBatchPromises: (
  array<promise<SQS.DeleteMessageBatchCommand.output>>,
  array<SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry>,
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
  entries: array<SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry>,
) => {
  let arraySize =
    (entries->Array.length->Int.toFloat /. maxBatchMessages->Int.toFloat)->Math.Int.ceil

  (
    await Array.fromInitializer(~length=arraySize, batchNr => {
      let start = batchNr * maxBatchMessages
      let end = start + maxBatchMessages
      SQS.DeleteMessageBatchCommand.send(
        SQS.DeleteMessageBatchCommand.make({
          queueUrl: queueId,
          entries: entries->Array.slice(~start, ~end),
        }),
      )
    })->handleDeleteBatchPromises(entries, "deleteMessagesParallel")
  )->handleBatchResult
}

let getQueuePolicy = async queueArn => {
  let response = await SQS.GetQueueAttributesCommand.send(
    SQS.GetQueueAttributesCommand.make({
      attributeNames: ["Policy"],
      queueUrl: queueArn->arn2Url,
    }),
  )

  response.attributes.policy->SQS.GetQueueAttributesCommand.unsafeParsePolicy
}

let setQueuePolicy = async (queueArn, policy: IAM.Policy.t) =>
  switch policy->JSON.stringifyAny {
  | Some(newPolicy) =>
    let _setQueueAttributesResponse = await SQS.SetQueueAttributesCommand.send(
      SQS.SetQueueAttributesCommand.make({
        attributes: {
          policy: newPolicy,
        },
        queueUrl: queueArn->arn2Url,
      }),
    )
  | None => Console.log("Couldn't stringify policy")
  }
