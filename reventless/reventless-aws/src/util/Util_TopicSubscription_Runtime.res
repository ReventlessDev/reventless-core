let subscribe = (~channelId, ~topicId) =>
  Effect.tryPromise(
    ~catch=SQS_Error.classify,
    () => AwsSdk.SNS_Helpers.subscribeQueueToTopic(channelId, topicId),
  )
  ->Effect.map(_ => ())
  ->Effect.retry(SQS_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = SQS_Error.message(err)
    Effect.logError("Failed to subscribe channel to topic: " ++ msg)
    ->Effect.flatMap(_ => Effect.fail(err))
  })
  ->Effect.runPromise

let unsubscribe = (~channelId, ~topicId) =>
  Effect.tryPromise(
    ~catch=SQS_Error.classify,
    () => AwsSdk.SNS_Helpers.unsubscribeQueueFromTopic(channelId, topicId),
  )
  ->Effect.map(_ => ())
  ->Effect.retry(SQS_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = SQS_Error.message(err)
    Effect.logError("Failed to unsubscribe channel from topic: " ++ msg)
    ->Effect.flatMap(_ => Effect.fail(err))
  })
  ->Effect.runPromise
