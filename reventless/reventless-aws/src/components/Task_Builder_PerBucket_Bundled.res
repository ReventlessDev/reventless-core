module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)
module TaskBucket = TaskBucket.S3
module TaskRuntimeBuilder = TaskRuntime_Builder_PerBucket_Bundled
module SideEffectHandler = SideEffectHandler_PerSideEffectHandler

module type BundledConfig = {
  let callbackModulePaths: dict<string>
  let publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>
}

module Make = (Spec: ReventlessCore.Task.Spec, Config: BundledConfig): (
  ReventlessCore.Task.T with module Spec = Spec
) => {
  module Inner = ReventlessCore.Task_Builder.Make(
    Spec,
    RuntimeEnvironment,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    TaskRuntimeBuilder,
    TaskBucket,
    SideEffectHandler,
  )

  module Spec = Spec

  type component = Inner.component

  let make = (
    ~queryBucketName,
    ~scheduler,
    ~publishToAggregates,
    ~queryEngine,
    ~resourceNaming,
    ~allAggregates,
    ~opts,
  ) => {
    Config.callbackModulePaths->Dict.forEachWithKey((modulePath, bucketName) => {
      TaskRuntimeBuilder.registerBundledTaskBucket(
        ~bucketName,
        ~callbackModulePath=modulePath,
        ~publishToAggregatesQueueUrls=Config.publishToAggregatesQueueUrls,
      )
    })

    Inner.make(
      ~queryBucketName,
      ~scheduler,
      ~publishToAggregates,
      ~queryEngine,
      ~resourceNaming,
      ~allAggregates,
      ~opts,
    )
  }

  let outputs = Inner.outputs
}
