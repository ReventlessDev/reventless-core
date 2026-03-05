let subscribe = (~channelId, ~topicId) =>
  Effect.tryPromise(
    ~catch=err => err,
    () => AwsSdk.SNS.subscribeQueueToTopic(channelId, topicId),
  )
  ->Effect.map(_ => ())
  ->Effect.catchAll(err =>
    Effect.logError("Failed to subscribe channel to topic")
    ->Effect.flatMap(_ => Effect.fail(err))
  )
  ->Effect.runPromise

let unsubscribe = (~channelId, ~topicId) =>
  Effect.tryPromise(
    ~catch=err => err,
    () => AwsSdk.SNS.unsubscribeQueueFromTopic(channelId, topicId),
  )
  ->Effect.map(_ => ())
  ->Effect.catchAll(err =>
    Effect.logError("Failed to unsubscribe channel from topic")
    ->Effect.flatMap(_ => Effect.fail(err))
  )
  ->Effect.runPromise
