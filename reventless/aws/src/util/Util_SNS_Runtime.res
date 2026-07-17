type resolvedTopic = {
  id: string,
  name: string,
  arn: string,
}

let publish = (topic, message) =>
  Effect.tryPromise(
    ~catch=SNS_Error.classify,
    () => AwsSdk.SNS_Helpers.publish(~topicArn=topic.arn, message),
  )
  ->Effect.map(_ => ())
  ->Effect.retry(SNS_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = SNS_Error.message(err)
    ReventlessCore.EffectLogger.logError(~comp=__MODULE__, "publish: " ++ msg)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
  ->Effect.runPromise

let publishFifo = (topic, ~messageGroupId, ~message) =>
  Effect.tryPromise(
    ~catch=SNS_Error.classify,
    () => AwsSdk.SNS_Helpers.publish(~topicArn=topic.arn, ~messageGroupId, message),
  )
  ->Effect.map(_ => ())
  ->Effect.retry(SNS_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = SNS_Error.message(err)
    ReventlessCore.EffectLogger.logError(~comp=__MODULE__, "publishFifo: " ++ msg)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
  ->Effect.runPromise
