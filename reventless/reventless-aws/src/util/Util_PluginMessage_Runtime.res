let sendMessage = (~channelId, ~messageBody) =>
  Effect.tryPromise(
    ~catch=SQS_Error.classify,
    () => AwsSdk.SQS_Helpers.sendMessage(~queueId=channelId, ~messageBody),
  )
  ->Effect.map(_ => ())
  ->Effect.retry(SQS_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = SQS_Error.message(err)
    Effect.logError("Failed to send message to channel: " ++ msg)
    ->Effect.flatMap(_ => Effect.fail(err))
  })
  ->Effect.runPromise
