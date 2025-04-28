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

    let publishCommands: Task.publishCommands = (aggregateName, cmdJsons) => {
      (publishToAggregates->Js.Dict.get(aggregateName)->Option.getExn)(cmdJsons)
    }

    let config = Spec.setup(queryEngine, scheduler, publishCommands, queryBucketName, opts)

    let bucketNames = config.buckets->Option.map(buckets =>
      buckets
      ->Array.map(({bucketName, callback}) => {
        let name = taskName ++ bucketName
        let bucket = TaskBucket.make(~name, ~opts)
        let handler = TaskBucket.makeHandler(callback)
        self->TaskRuntimeBuilder.forBucketCallback(
          ~handler,
          ~connect=TaskBucket.connect(~name, ~bucket, ~opts, ...),
          ~memorySize=4096,
          ~timeout=600
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
          ~allCommandTopics=allAggregates->Aggregate.allCommandTopics,
          ~queryEngine,
          ~scheduler,
          ~opts,
        )
      )

    let sideEffects =
      config.sideEffects->Option.map(sideEffect =>
        sideEffect->Array.map((module(SideEffect)) => SideEffect.Source.name)
      )
    self->Component.setOutputs({name: taskName, ?bucketNames, ?sideEffects})
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
      ~name=Spec.name->ComponentType.name(Task.componentType),
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
