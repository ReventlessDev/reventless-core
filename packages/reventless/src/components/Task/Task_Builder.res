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
  SpecificSideEffectHandler: SideEffectHandler.T,
): Task.T => {
  module Spec = Spec
  // type handler = Runtime.eventHandler<
  //   TaskRuntimeBuilder.callbackEvent,
  //   TaskRuntimeBuilder.context,
  //   array<Task.taskAction>,
  // >

  let construct = (
    ~queryBucketName,
    ~scheduler,
    ~publishToAggregates,
    ~queryEngine,
    ~resourceNaming: ReventlessSpec.ResourceNaming.operations,
    ~allAggregates,
    self,
    taskName,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let allCommandTopics = allAggregates->Aggregate.allCommandTopics

    let publishCommands: Task.publishCommands = (aggregateName, cmdJsons) => {
      (publishToAggregates->Dict.get(aggregateName)->Option.getOrThrow)(cmdJsons)
    }

    let config = Spec.setup(queryEngine, queryBucketName, opts)

    let sideEffectHandler =
      config.sideEffects->Option.map(sideEffects =>
        SpecificSideEffectHandler.make(
          ~name=taskName,
          ~sideEffects,
          ~allEventTopics=allAggregates->Aggregate.allEventTopics,
          ~allCommandTopics,
          ~queryEngine,
          ~scheduler,
          ~resourceNaming,
          ~opts,
        )
      )

    let taskActionsHandler = (taskActions, operations: option<SideEffectHandler.operations>) => {
      taskActions
      ->Array.map(async taskAction => {
        switch taskAction {
        | Task.PublishCommands(aggregateName, cmdJsons) =>
          await publishCommands(aggregateName, cmdJsons)
        | CreateSchedule(schedule) =>
          switch operations {
          | Some(operations) => await operations.createSchedule(schedule)
          | None => Console.log("No SideEffectHandler to create schedule")
          }
        | DeleteSchedule(scheduleId) =>
          switch operations {
          | Some(operations) => await operations.deleteSchedule(scheduleId)
          | None => Console.log("No SideEffectHandler to delete schedule")
          }
        }
      })
      ->Promise.all
      ->Util.Promise.toUnit
    }

    let createHandler = (sideEffectHandler, callback) => {
      let handler = callback->TaskBucket.makeHandler
      switch sideEffectHandler {
      | Some(sideEffectHandler) =>
        sideEffectHandler
        ->Component.operations
        ->Pulumi.Output.apply(operations =>
          async (event, context) => {
            let taskActions = await handler(event, context)
            await taskActions->taskActionsHandler(Some(operations))
          }
        )
      | None =>
        (
          async (event, context) => {
            let taskActions = await handler(event, context)
            await taskActions->taskActionsHandler(None)
          }
        )->Pulumi.Output.make
      }
    }

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
              ~handler=sideEffectHandler->createHandler(callback),
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
              ~name=bucketName,
            ),
        )

        (bucketName, (bucket.resources->Array.getUnsafe(0)).id)
      })
      ->Dict.fromArray
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
    ~resourceNaming,
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
        ~resourceNaming,
        ~allAggregates,
        ...
      ),
      ~opts,
    )
}
