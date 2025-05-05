module Make = (
  Spec: Task.Spec,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
  TaskRuntimeBuilder: TaskRuntime_Builder.T with type runtimeParts = RuntimeEnvironment.parts,
  TaskBucket: Task_Adapter.Bucket
    with type runtimeParts = RuntimeEnvironment.parts
    and type callbackEvent = TaskRuntimeBuilder.callbackEvent
    and type runtimeParts = RuntimeEnvironment.parts
    and type context = TaskRuntimeBuilder.context,
  SideEffectHandler: SideEffectHandler.T,
): Task.T => {
  module Spec = Spec
  type handler = Runtime.eventHandler<
    TaskRuntimeBuilder.callbackEvent,
    TaskRuntimeBuilder.context,
    array<Task.taskAction>,
  >

  let construct = (
    ~queryBucketName,
    ~scheduler,
    ~publishToAggregates,
    ~queryEngine,
    ~allAggregates,
    self,
    taskName,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let allCommandTopics = allAggregates->Aggregate.allCommandTopics

    let publishCommands: Task.publishCommands = (aggregateName, cmdJsons) => {
      (publishToAggregates->Dict.get(aggregateName)->Option.getExn)(cmdJsons)
    }

    let taskActionsHandler = (handler: handler) => async (event, context) => {
      let taskActions = await handler(event, context)
      await taskActions
      ->Array.map(async taskAction => {
        switch taskAction {
        | PublishCommands(aggregateName, cmdJsons) => await publishCommands(aggregateName, cmdJsons)
        }
      })
      ->Promise.all
      ->Util.Promise.toUnit
    }

    let config = Spec.setup(queryEngine, scheduler, queryBucketName, opts)

    let bucketNames = config.buckets->Option.map(buckets =>
      buckets
      ->Array.map(bucketSpec => {
        let bucketName = bucketSpec.bucketName->Option.getOr("Bucket")
        let name = taskName ++ bucketName
        let bucket = TaskBucket.make(~name, ~opts)
        let opts = {Pulumi.ComponentResource.parent: bucket.parts->Pulumi.Resource.makeFromJs}

        bucketSpec.callback->Option.forEach(
          callback =>
            self->TaskRuntimeBuilder.forBucketCallback(
              ~handler=callback->TaskBucket.makeHandler->taskActionsHandler->Pulumi.Output.make,
              ~connect=TaskBucket.connect(
                ~name,
                ~bucket,
                ~bucketMode=bucketSpec.bucketMode,
                ~commandTopics=allCommandTopics,
                ~opts,
                ...
              ),
              ~memorySize=4096,
              ~timeout=600,
              ~name=bucketName
            ),
        )

        (bucketName, (bucket.resources->Array.getUnsafe(0)).id)
      })
      ->Dict.fromArray
    )

    let _sideEffectHandler =
      config.sideEffects->Option.map(sideEffects =>
        SideEffectHandler.make(
          ~name=taskName,
          ~sideEffects,
          ~allEventTopics=allAggregates->Aggregate.allEventTopics,
          ~allCommandTopics,
          ~queryEngine,
          ~scheduler,
          ~opts,
        )
      )

    let sideEffectSources =
      config.sideEffects->Option.map(sideEffect =>
        sideEffect->Array.map((module(SideEffect)) => SideEffect.Source.name)
      )
    self->Component.setOutputs({name: taskName, ?bucketNames, ?sideEffectSources})
  }

  let make = (
    ~queryBucketName,
    ~scheduler,
    ~publishToAggregates,
    ~queryEngine,
    ~allAggregates,
    ~opts,
  ) =>
    Component.make(
      ~componentType=Task.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(
        ~queryBucketName,
        ~scheduler,
        ~publishToAggregates,
        ~queryEngine,
        ~allAggregates,
        ...
      ),
      ~opts
    )
}
