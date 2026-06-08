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
    ~name,
    ~callbackModulePath as _,
    ~publishToAggregatesQueueUrls as _,
    ~schedulerConfig as _,
    task: Task.component,
  ) => {
    let resource = task->Component.toPulumiResource
    // `name` is the PascalCase bucket stem; give the side-effect handler the
    // SideEffectHandler kind (matches the AWS TaskRuntime builder).
    let name = resource.name->Option.getOr("UnnamedTask") ++ name ++ "SideEffectHandler"
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
