module Make = (
  RuntimeEnvironment: Runtime.Environment,
  TaskBucket: Task_Adapter.Bucket
    with type runtimeParts = RuntimeEnvironment.parts
    and type context = RuntimeEnvironment.context,
): (
  TaskRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and type callbackEvent = TaskBucket.callbackEvent
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  type callbackEvent = TaskBucket.callbackEvent

  let forBucketCallback = (
    ~handler,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    task: Task.component,
  ) => {
    let resource = task->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(EventCollector.componentType)
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(handler => handler->RuntimeEnvironment.asEventHandler),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    let _connectResources = connect(~runtime)
  }

  let finish = () => ()
}
