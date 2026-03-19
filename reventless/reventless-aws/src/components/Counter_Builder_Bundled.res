module type BundledConfig = {
  let targetSpecModulePath: string
  let mappingsModulePath: string
  let publishQueueUrl: Pulumi.Output.t<string>
}

module Make = (
  Api: {
    let api: Types.AppSync.api
    let apiRole: Types.AppSync.role
  },
  Config: BundledConfig,
) => {
  module Inner = ReventlessCore.Counter_Builder.Make(
    QueryDbStorage_DynamoDbStream,
    Api,
    CounterHandler_DynamoDbStream_Bundled,
  )

  type component = Inner.component

  let make = (~name, ~jsonEventsHandler, ~ttl=?, ~opts=?) => {
    CounterHandler_DynamoDbStream_Bundled.registerBundledCounter(
      ~counterName=name->ReventlessCore.ComponentType.name(ReventlessCore.Counter.componentType),
      ~targetSpecModulePath=Config.targetSpecModulePath,
      ~mappingsModulePath=Config.mappingsModulePath,
      ~publishQueueUrl=Config.publishQueueUrl,
    )

    Inner.make(~name, ~jsonEventsHandler, ~ttl?, ~opts?)
  }

  let outputs = Inner.outputs
  let operations = Inner.operations
}
