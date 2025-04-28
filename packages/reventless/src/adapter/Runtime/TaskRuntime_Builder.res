module type T = {
  type context
  type callbackEvent
  type runtimeParts

  let forBucketCallback: Runtime.forComponent<
    Runtime.eventHandler<callbackEvent, context, unit>,
    runtimeParts,
    Task.component,
  >
  let finish: unit => unit
}
