let sendMessage = (~channelId, ~messageBody) =>
  Effect.tryPromise(
    ~catch=err => err,
    () => AwsSdk.SQS.sendMessage(~queueId=channelId, ~messageBody),
  )
  ->Effect.map(_ => ())
  ->Effect.catchAll(err =>
    Effect.logError("Failed to send message to channel")
    ->Effect.flatMap(_ => Effect.fail(err))
  )
  ->Effect.runPromise
